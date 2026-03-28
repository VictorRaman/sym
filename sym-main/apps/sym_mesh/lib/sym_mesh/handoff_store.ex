defmodule LemonMesh.HandoffStore do
  @moduledoc """
  Typed wrapper for durable mesh handoff bookkeeping.
  """

  require Logger

  alias LemonCore.{Id, Store}
  alias LemonMesh.OpLog
  alias LemonMesh.Replication.Projector

  @table :mesh_handoff_ops

  @type t :: %__MODULE__{
          handoff_id: String.t(),
          mesh_session_id: String.t(),
          agent_id: String.t(),
          prompt: String.t(),
          queue_mode: String.t(),
          delivery_state:
            :created
            | :delivery_accepted
            | :mailbox_persisted
            | :blackboard_persisted
            | :runtime_accepted
            | :runtime_applied
            | :completed
            | :failed,
          meta: map(),
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          message_id: String.t() | nil,
          handoff_entry_id: String.t() | nil,
          delivery_sent_at_ms: non_neg_integer() | nil,
          send_failed_at_ms: non_neg_integer() | nil,
          mailbox_persisted_at_ms: non_neg_integer() | nil,
          blackboard_persisted_at_ms: non_neg_integer() | nil,
          runtime_accepted_at_ms: non_neg_integer() | nil,
          runtime_applied_at_ms: non_neg_integer() | nil,
          completed_at_ms: non_neg_integer() | nil
        }

  defstruct [
    :handoff_id,
    :mesh_session_id,
    :agent_id,
    :prompt,
    :queue_mode,
    :delivery_state,
    :meta,
    :run_id,
    :session_key,
    :message_id,
    :handoff_entry_id,
    :delivery_sent_at_ms,
    :send_failed_at_ms,
    :mailbox_persisted_at_ms,
    :blackboard_persisted_at_ms,
    :runtime_accepted_at_ms,
    :runtime_applied_at_ms,
    :completed_at_ms
  ]

  @spec create(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def create(attrs) do
    handoff = new(attrs)
    authoritative_write(handoff, "created")
  end

  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(handoff_id) when is_binary(handoff_id) do
    case Store.get(@table, handoff_id) do
      nil -> {:error, :not_found}
      payload when is_map(payload) -> {:ok, from_map(payload)}
    end
  end

  @spec mark_delivery(String.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def mark_delivery(handoff_id, attrs) when is_binary(handoff_id) do
    update(handoff_id, attrs, "delivery_accepted", fn handoff, updates ->
      handoff
      |> Map.put(:run_id, fetch(updates, :run_id, handoff.run_id))
      |> Map.put(:session_key, fetch(updates, :session_key, handoff.session_key))
      |> Map.put(
        :delivery_sent_at_ms,
        fetch(updates, :delivery_sent_at_ms, System.system_time(:millisecond))
      )
      |> put_delivery_state(:delivery_accepted)
      |> Map.put(:send_failed_at_ms, nil)
    end)
  end

  @spec mark_send_failed(String.t(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def mark_send_failed(handoff_id, failed_at_ms \\ nil) when is_binary(handoff_id) do
    update(
      handoff_id,
      %{send_failed_at_ms: failed_at_ms || System.system_time(:millisecond)},
      "failed",
      fn handoff, updates ->
        handoff
        |> Map.put(:delivery_state, :failed)
        |> Map.put(:send_failed_at_ms, fetch(updates, :send_failed_at_ms))
      end
    )
  end

  @spec mark_mailbox_persisted(String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, term()}
  def mark_mailbox_persisted(handoff_id, message_id, persisted_at_ms \\ nil)
      when is_binary(handoff_id) and is_binary(message_id) do
    update(
      handoff_id,
      %{
        message_id: message_id,
        mailbox_persisted_at_ms: persisted_at_ms || System.system_time(:millisecond)
      },
      "mailbox_persisted",
      fn handoff, updates ->
        handoff
        |> Map.put(:message_id, fetch(updates, :message_id))
        |> Map.put(:mailbox_persisted_at_ms, fetch(updates, :mailbox_persisted_at_ms))
        |> put_delivery_state(:mailbox_persisted)
      end
    )
  end

  @spec mark_blackboard_persisted(String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, term()}
  def mark_blackboard_persisted(handoff_id, handoff_entry_id, persisted_at_ms \\ nil)
      when is_binary(handoff_id) and is_binary(handoff_entry_id) do
    update(
      handoff_id,
      %{
        handoff_entry_id: handoff_entry_id,
        blackboard_persisted_at_ms: persisted_at_ms || System.system_time(:millisecond)
      },
      "blackboard_persisted",
      fn handoff, updates ->
        handoff
        |> Map.put(:handoff_entry_id, fetch(updates, :handoff_entry_id))
        |> Map.put(:blackboard_persisted_at_ms, fetch(updates, :blackboard_persisted_at_ms))
        |> put_delivery_state(:blackboard_persisted)
      end
    )
  end

  @spec mark_runtime_accepted(String.t(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, term()}
  def mark_runtime_accepted(handoff_id, accepted_at_ms \\ nil) when is_binary(handoff_id) do
    update(
      handoff_id,
      %{runtime_accepted_at_ms: accepted_at_ms || System.system_time(:millisecond)},
      "runtime_accepted",
      fn handoff, updates ->
        handoff
        |> Map.put(:runtime_accepted_at_ms, fetch(updates, :runtime_accepted_at_ms))
        |> put_delivery_state(:runtime_accepted)
      end
    )
  end

  @spec mark_runtime_applied(String.t(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def mark_runtime_applied(handoff_id, applied_at_ms \\ nil) when is_binary(handoff_id) do
    update(
      handoff_id,
      %{runtime_applied_at_ms: applied_at_ms || System.system_time(:millisecond)},
      "runtime_applied",
      fn handoff, updates ->
        handoff
        |> Map.put(:runtime_applied_at_ms, fetch(updates, :runtime_applied_at_ms))
        |> put_delivery_state(:runtime_applied)
      end
    )
  end

  @spec mark_completed(String.t(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def mark_completed(handoff_id, completed_at_ms \\ nil) when is_binary(handoff_id) do
    update(
      handoff_id,
      %{completed_at_ms: completed_at_ms || System.system_time(:millisecond)},
      "completed",
      fn handoff, updates ->
        handoff
        |> Map.put(:completed_at_ms, fetch(updates, :completed_at_ms))
        |> put_delivery_state(:completed)
      end
    )
  end

  @spec list_reconcilable() :: [t()]
  def list_reconcilable do
    @table
    |> Store.list()
    |> Enum.map(fn {_key, payload} -> from_map(payload) end)
    |> Enum.filter(fn handoff ->
      handoff.delivery_state in [:created, :delivery_accepted, :mailbox_persisted] and
        is_nil(handoff.completed_at_ms)
    end)
    |> Enum.sort_by(&{&1.delivery_sent_at_ms || 0, &1.handoff_id}, :asc)
  end

  @spec reset() :: :ok
  def reset do
    for {stored_key, _value} <- Store.list(@table) do
      Store.delete(@table, stored_key)
    end

    :ok
  end

  defp new(attrs) do
    attrs = normalize_map(attrs)

    %__MODULE__{
      handoff_id: fetch(attrs, :handoff_id, "handoff_#{Id.uuid()}"),
      mesh_session_id: fetch(attrs, :mesh_session_id),
      agent_id: fetch(attrs, :agent_id),
      prompt: fetch(attrs, :prompt),
      queue_mode: normalize_queue_mode(fetch(attrs, :queue_mode)),
      delivery_state: normalize_delivery_state(attrs),
      meta: fetch(attrs, :meta, %{}) || %{},
      run_id: fetch(attrs, :run_id),
      session_key: fetch(attrs, :session_key),
      message_id: fetch(attrs, :message_id),
      handoff_entry_id: fetch(attrs, :handoff_entry_id),
      delivery_sent_at_ms: fetch(attrs, :delivery_sent_at_ms),
      send_failed_at_ms: fetch(attrs, :send_failed_at_ms),
      mailbox_persisted_at_ms: fetch(attrs, :mailbox_persisted_at_ms),
      blackboard_persisted_at_ms: fetch(attrs, :blackboard_persisted_at_ms),
      runtime_accepted_at_ms: fetch(attrs, :runtime_accepted_at_ms),
      runtime_applied_at_ms: fetch(attrs, :runtime_applied_at_ms),
      completed_at_ms: fetch(attrs, :completed_at_ms)
    }
  end

  defp from_map(map) when is_map(map), do: new(map)

  defp to_map(%__MODULE__{} = handoff) do
    %{
      handoff_id: handoff.handoff_id,
      mesh_session_id: handoff.mesh_session_id,
      agent_id: handoff.agent_id,
      prompt: handoff.prompt,
      queue_mode: handoff.queue_mode,
      delivery_state: handoff.delivery_state,
      meta: handoff.meta,
      run_id: handoff.run_id,
      session_key: handoff.session_key,
      message_id: handoff.message_id,
      handoff_entry_id: handoff.handoff_entry_id,
      delivery_sent_at_ms: handoff.delivery_sent_at_ms,
      send_failed_at_ms: handoff.send_failed_at_ms,
      mailbox_persisted_at_ms: handoff.mailbox_persisted_at_ms,
      blackboard_persisted_at_ms: handoff.blackboard_persisted_at_ms,
      runtime_accepted_at_ms: handoff.runtime_accepted_at_ms,
      runtime_applied_at_ms: handoff.runtime_applied_at_ms,
      completed_at_ms: handoff.completed_at_ms
    }
  end

  defp update(handoff_id, attrs, op_type, updater) do
    attrs = normalize_map(attrs)

    with {:ok, handoff} <- load_for_update(handoff_id) do
      handoff
      |> updater.(attrs)
      |> authoritative_write(op_type)
    end
  end

  defp authoritative_write(%__MODULE__{} = handoff, op_type) do
    case OpLog.append(%{
           op_id: "#{handoff.handoff_id}:#{op_type}",
           entity_type: "handoff",
           entity_id: handoff.handoff_id,
           op_type: op_type,
           payload: to_map(handoff)
         }) do
      {:ok, op} ->
        Projector.project(op)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_for_update(handoff_id) do
    case get(handoff_id) do
      {:ok, handoff} ->
        {:ok, handoff}

      {:error, :not_found} ->
        Projector.rebuild_entity("handoff", handoff_id)
    end
  end

  defp normalize_queue_mode(nil), do: "followup"
  defp normalize_queue_mode(mode) when is_binary(mode), do: mode
  defp normalize_queue_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp normalize_queue_mode(_mode), do: "followup"

  defp normalize_delivery_state(attrs) do
    explicit = normalize_explicit_delivery_state(fetch(attrs, :delivery_state))
    delivery_sent_at_ms = fetch(attrs, :delivery_sent_at_ms)
    send_failed_at_ms = fetch(attrs, :send_failed_at_ms)

    cond do
      explicit != nil ->
        explicit

      is_integer(fetch(attrs, :completed_at_ms)) ->
        :completed

      is_integer(send_failed_at_ms) ->
        :failed

      is_integer(fetch(attrs, :runtime_applied_at_ms)) ->
        :runtime_applied

      is_integer(fetch(attrs, :runtime_accepted_at_ms)) ->
        :runtime_accepted

      is_integer(fetch(attrs, :blackboard_persisted_at_ms)) ->
        :blackboard_persisted

      is_integer(fetch(attrs, :mailbox_persisted_at_ms)) ->
        :mailbox_persisted

      is_integer(delivery_sent_at_ms) ->
        :delivery_accepted

      true ->
        :created
    end
  end

  defp normalize_explicit_delivery_state(:created), do: :created
  defp normalize_explicit_delivery_state(:delivery_accepted), do: :delivery_accepted
  defp normalize_explicit_delivery_state(:mailbox_persisted), do: :mailbox_persisted
  defp normalize_explicit_delivery_state(:blackboard_persisted), do: :blackboard_persisted
  defp normalize_explicit_delivery_state(:runtime_accepted), do: :runtime_accepted
  defp normalize_explicit_delivery_state(:runtime_applied), do: :runtime_applied
  defp normalize_explicit_delivery_state(:completed), do: :completed
  defp normalize_explicit_delivery_state(:failed), do: :failed
  defp normalize_explicit_delivery_state("created"), do: :created
  defp normalize_explicit_delivery_state("accepted"), do: :delivery_accepted
  defp normalize_explicit_delivery_state("delivery_accepted"), do: :delivery_accepted
  defp normalize_explicit_delivery_state("mailbox_persisted"), do: :mailbox_persisted
  defp normalize_explicit_delivery_state("blackboard_persisted"), do: :blackboard_persisted
  defp normalize_explicit_delivery_state("runtime_accepted"), do: :runtime_accepted
  defp normalize_explicit_delivery_state("runtime_applied"), do: :runtime_applied
  defp normalize_explicit_delivery_state("completed"), do: :completed
  defp normalize_explicit_delivery_state("failed"), do: :failed
  defp normalize_explicit_delivery_state(_state), do: nil

  defp put_delivery_state(%__MODULE__{delivery_state: current} = handoff, target) do
    next_state =
      case {current, target} do
        {:failed, _} -> :failed
        {:completed, _} -> :completed
        {_current, target} -> target
      end

    %{handoff | delivery_state: next_state}
  end

  defp normalize_map(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_map(attrs) when is_map(attrs), do: attrs
  defp normalize_map(_attrs), do: %{}

  defp fetch(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
