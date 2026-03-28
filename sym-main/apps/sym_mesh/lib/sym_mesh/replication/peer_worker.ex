defmodule LemonMesh.Replication.PeerWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonMesh.{NodeIdentity, OpLog}
  alias LemonMesh.Replication.{Projector, Snapshot, Watermark}

  defstruct [
    :peer_id,
    :transport,
    :poll_interval_ms,
    :batch_limit,
    :snapshot_scope,
    :bootstrap_state,
    :bootstrap_target_watermark,
    :bootstrapped?,
    :last_success_at_ms,
    :last_error,
    :last_snapshot_at_ms
  ]

  @type t :: %__MODULE__{}

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :peer_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      peer_id: Keyword.fetch!(opts, :peer_id),
      transport: Keyword.fetch!(opts, :transport),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 1_000),
      batch_limit: Keyword.get(opts, :batch_limit, 200),
      snapshot_scope: Keyword.get(opts, :snapshot_scope, "mesh_state"),
      bootstrap_state: :bootstrapping,
      bootstrap_target_watermark: nil,
      bootstrapped?: false,
      last_success_at_ms: nil,
      last_error: nil,
      last_snapshot_at_ms: nil
    }

    send(self(), :sync_tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    inbound_watermark = Watermark.inbound(state.peer_id)

    status =
      %{
        peer_id: state.peer_id,
        status: current_status(state),
        bootstrapped?: state.bootstrapped?,
        bootstrap_state: state.bootstrap_state,
        bootstrap_target_watermark: state.bootstrap_target_watermark,
        backfill_complete: backfill_complete?(inbound_watermark, state.bootstrap_target_watermark),
        backfill_lag: backfill_lag(inbound_watermark, state.bootstrap_target_watermark),
        last_success_at_ms: state.last_success_at_ms,
        last_error: state.last_error,
        last_snapshot_at_ms: state.last_snapshot_at_ms
      }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:sync_tick, state) do
    next_state = sync(state)
    Process.send_after(self(), :sync_tick, state.poll_interval_ms)
    {:noreply, next_state}
  end

  defp sync(state) do
    with {:ok, state} <- maybe_bootstrap(state),
         {:ok, state} <- pull_and_project(state) do
      state
      |> maybe_mark_bootstrapped()
      |> Map.put(:last_error, nil)
      |> Map.put(:last_success_at_ms, System.system_time(:millisecond))
    else
      {:error, reason, partial_state} ->
        next_state = %{(partial_state || state) | last_error: reason}

        if state.last_error != reason do
          Logger.warning(
            "Mesh replication worker peer=#{state.peer_id} failed: #{inspect(reason)}"
          )
        end

        next_state
    end
  end

  defp maybe_bootstrap(%__MODULE__{bootstrap_state: :needs_reseed} = state) do
    {:error, :local_state_requires_reseed, state}
  end

  defp maybe_bootstrap(%__MODULE__{bootstrapped?: true} = state), do: {:ok, state}

  defp maybe_bootstrap(state) do
    inbound_watermark = Watermark.inbound(state.peer_id)

    case state.bootstrap_target_watermark do
      target when is_map(target) ->
        {:ok, maybe_mark_bootstrapped(%{state | bootstrap_state: :bootstrapping})}

      _ ->
        bootstrap_from_snapshot(state, inbound_watermark)
    end
  end

  defp bootstrap_from_snapshot(state, inbound_watermark) do
    local_state_empty? = Snapshot.authority_state_empty?()

    if not local_state_empty? and inbound_watermark == %{} do
      {:error, :local_state_requires_reseed,
       %{state | bootstrapped?: false, bootstrap_state: :needs_reseed}}
    else
      case state.transport.get_snapshot(
             state.peer_id,
             state.snapshot_scope,
             requester_id: NodeIdentity.current_node_id()
           ) do
        {:ok, snapshot} ->
          with :ok <- maybe_install_snapshot(snapshot, local_state_empty?) do
            {:ok,
             state
             |> Map.put(:bootstrap_state, :bootstrapping)
             |> Map.put(:bootstrap_target_watermark, snapshot["watermark"] || %{})
             |> Map.put(:last_snapshot_at_ms, System.system_time(:millisecond))
             |> maybe_mark_bootstrapped()}
          else
            {:error, reason} ->
              {:error, reason, %{state | bootstrap_state: :error}}
          end

        {:error, reason} ->
          {:error, reason, %{state | bootstrap_state: :error}}
      end
    end
  end

  defp maybe_install_snapshot(snapshot, true) do
    case Snapshot.install(snapshot) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_install_snapshot(_snapshot, false), do: :ok

  defp pull_and_project(state) do
    case state.transport.pull_ops(
           state.peer_id,
           Watermark.inbound(state.peer_id),
           state.batch_limit,
           requester_id: NodeIdentity.current_node_id()
         ) do
      {:ok, ops} ->
        Enum.reduce_while(ops, {:ok, state}, fn op, {:ok, current_state} ->
          case process_op(state.peer_id, op) do
            :ok -> {:cont, {:ok, current_state}}
            {:error, reason} -> {:halt, {:error, reason, current_state}}
          end
        end)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp process_op(peer_id, op) do
    with {:ok, stored_op} <- OpLog.append(op_to_payload(op)),
         :ok <- maybe_project(stored_op),
         {:ok, _watermark} <- Watermark.advance_inbound(peer_id, stored_op) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(%{entity_type: "handoff"} = op) do
    case Projector.project(op) do
      {:ok, _handoff} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(%{entity_type: "manifest"} = op) do
    case Projector.project(op) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(%{entity_type: "blackboard"} = op) do
    case Projector.project(op) do
      {:ok, _entries} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(%{entity_type: "worktree_lease"} = op) do
    case Projector.project(op) do
      {:ok, _lease} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(%{entity_type: "peer_mailbox"} = op) do
    case Projector.project(op) do
      {:ok, _peer_messages} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_project(_op), do: :ok

  defp op_to_payload(%_{} = op), do: Map.from_struct(op)
  defp op_to_payload(op), do: op

  defp maybe_mark_bootstrapped(%__MODULE__{bootstrap_state: :needs_reseed} = state), do: state

  defp maybe_mark_bootstrapped(%__MODULE__{} = state) do
    target_watermark = state.bootstrap_target_watermark || %{}
    inbound_watermark = Watermark.inbound(state.peer_id)

    if backfill_complete?(inbound_watermark, target_watermark) do
      %{state | bootstrapped?: true, bootstrap_state: :bootstrapped}
    else
      %{state | bootstrapped?: false, bootstrap_state: :bootstrapping}
    end
  end

  defp backfill_complete?(inbound_watermark, target_watermark) do
    backfill_lag(inbound_watermark, target_watermark) == 0
  end

  defp backfill_lag(inbound_watermark, target_watermark)
       when is_map(inbound_watermark) and is_map(target_watermark) do
    Enum.reduce(target_watermark, 0, fn {node_id, target_value}, acc ->
      acc + max(normalize_clock_value(target_value) - normalize_clock_value(inbound_watermark[node_id]), 0)
    end)
  end

  defp backfill_lag(_inbound_watermark, _target_watermark), do: 0

  defp normalize_clock_value(value) when is_integer(value) and value >= 0, do: value
  defp normalize_clock_value(_value), do: 0

  defp current_status(%__MODULE__{bootstrap_state: :needs_reseed}), do: :degraded
  defp current_status(%__MODULE__{last_error: nil}), do: :healthy
  defp current_status(%__MODULE__{}), do: :degraded
end
