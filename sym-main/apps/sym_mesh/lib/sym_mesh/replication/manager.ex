defmodule LemonMesh.Replication.Manager do
  @moduledoc false

  use GenServer

  alias LemonMesh.{Config, NodeIdentity}
  alias LemonMesh.Replication.Watermark

  defstruct [
    :config_loader,
    :worker_supervisor,
    :peer_worker_module,
    :transport,
    :cwd,
    :trusted_peers,
    :peers,
    :replication_poll_interval_ms,
    :replication_batch_limit,
    :snapshot_scope,
    :lease_ttl_ms
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    LemonCore.Bus.subscribe("system")

    state = %__MODULE__{
      config_loader:
        Keyword.get(opts, :config_loader, fn -> Config.load(Keyword.get(opts, :cwd)) end),
      worker_supervisor: Keyword.get(opts, :worker_supervisor, LemonMesh.ReplicationSupervisor),
      peer_worker_module:
        Keyword.get(opts, :peer_worker_module, LemonMesh.Replication.PeerWorker),
      transport: Keyword.get(opts, :transport, LemonMesh.Replication.BeamRpc),
      cwd: Keyword.get(opts, :cwd),
      trusted_peers: [],
      peers: %{},
      replication_poll_interval_ms: 1_000,
      replication_batch_limit: 200,
      snapshot_scope: "mesh_state",
      lease_ttl_ms: 60_000
    }

    {:ok, reconcile_membership(state, load_config(state))}
  end

  @impl true
  def handle_call(:status, _from, state) do
    peer_statuses =
      state.peers
      |> Enum.map(fn {peer_id, %{pid: pid}} ->
        worker_status =
          if Process.alive?(pid) and function_exported?(state.peer_worker_module, :status, 1) do
            state.peer_worker_module.status(pid)
          else
            %{peer_id: peer_id, status: :down, bootstrapped?: false, last_error: :down}
          end

        Map.put(worker_status, :peer_id, peer_id)
      end)
      |> Enum.sort_by(& &1.peer_id)

    {:reply,
     %{
       trusted_peers: state.trusted_peers,
       local_watermark: Watermark.local(),
       inbound_watermarks: Watermark.list_inbound(),
       outbound_watermarks: Watermark.list_outbound(),
       peers: peer_statuses
     }, state}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :config_reloaded}, state) do
    {:noreply, reconcile_membership(state, load_config(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp load_config(state) do
    loader = state.config_loader
    loader.()
  end

  defp reconcile_membership(state, config) when is_map(config) do
    desired =
      config
      |> Map.get(:trusted_peers, [])
      |> Enum.uniq()
      |> Enum.reject(&(&1 == NodeIdentity.current_node_id()))

    current = Map.keys(state.peers)

    to_start = desired -- current
    to_stop = current -- desired

    next_peers =
      Enum.reduce(to_start, state.peers, fn peer_id, acc ->
        case DynamicSupervisor.start_child(
               state.worker_supervisor,
               {state.peer_worker_module,
                peer_id: peer_id,
                transport: state.transport,
                poll_interval_ms: Map.get(config, :replication_poll_interval_ms, 1_000),
                batch_limit: Map.get(config, :replication_batch_limit, 200),
                snapshot_scope: Map.get(config, :snapshot_scope, "mesh_state")}
             ) do
          {:ok, pid} -> Map.put(acc, peer_id, %{pid: pid})
          {:error, {:already_started, pid}} -> Map.put(acc, peer_id, %{pid: pid})
          {:error, _reason} -> acc
        end
      end)

    next_peers =
      Enum.reduce(to_stop, next_peers, fn peer_id, acc ->
        case Map.fetch(acc, peer_id) do
          {:ok, %{pid: pid}} ->
            if Process.alive?(pid) do
              DynamicSupervisor.terminate_child(state.worker_supervisor, pid)
            end

            Map.delete(acc, peer_id)

          :error ->
            acc
        end
      end)

    %{
      state
      | trusted_peers: desired,
        peers: next_peers,
        replication_poll_interval_ms: Map.get(config, :replication_poll_interval_ms, 1_000),
        replication_batch_limit: Map.get(config, :replication_batch_limit, 200),
        snapshot_scope: Map.get(config, :snapshot_scope, "mesh_state"),
        lease_ttl_ms: Map.get(config, :lease_ttl_ms, 60_000)
    }
  end
end
