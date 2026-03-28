defmodule LemonMesh.Replication.Projector do
  @moduledoc false

  alias LemonCore.Store
  alias LemonMesh.{BlackboardEntry, HandoffStore, Op, OpLog, PeerEnvelope, WorktreeLease}
  alias LemonMesh.Store, as: MeshStore
  alias LemonMesh.Replication.Watermark

  @blackboard_table :mesh_blackboards
  @handoff_table :mesh_handoff_ops
  @peer_mailbox_table :mesh_peer_mailboxes
  @worktree_lease_table :mesh_worktree_leases

  @spec project(Op.t()) ::
          {:ok, HandoffStore.t() | [PeerEnvelope.t()] | [BlackboardEntry.t()] | map()}
          | {:error, term()}
  def project(%Op{entity_type: "manifest", entity_id: entity_id, payload: payload} = op) do
    session_snapshot =
      payload
      |> normalize_session_snapshot(entity_id)

    with true <- is_binary(session_snapshot.session_id) and session_snapshot.session_id != "",
         :ok <- MeshStore.project_session_snapshot(session_snapshot),
         {:ok, _watermark} <- Watermark.advance_local(op) do
      {:ok, session_snapshot}
    else
      false -> {:error, :invalid_manifest_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  def project(%Op{entity_type: "blackboard", entity_id: entity_id, payload: payload} = op) do
    session_id = payload_value(payload, :session_id) || entity_id
    incoming = BlackboardEntry.from_map(Map.put_new(payload, :session_id, session_id))

    with true <- is_binary(session_id) and session_id != "",
         updated_entries <-
           merge_blackboard_entry(current_blackboard_entries(session_id), incoming),
         :ok <- MeshStore.project_blackboard_entries(session_id, updated_entries),
         {:ok, _watermark} <- Watermark.advance_local(op) do
      {:ok, updated_entries}
    else
      false -> {:error, :invalid_blackboard_delta}
      {:error, reason} -> {:error, reason}
    end
  end

  def project(
        %Op{
          entity_type: "worktree_lease",
          entity_id: entity_id,
          op_type: op_type,
          origin_node_id: origin_node_id,
          payload: payload
        } = op
      ) do
    incoming =
      payload
      |> Map.put_new(:origin_node_id, origin_node_id)
      |> Map.put_new("origin_node_id", origin_node_id)
      |> WorktreeLease.new()

    merged = merge_worktree_lease(current_worktree_lease(entity_id), incoming, op_type)

    with :ok <- MeshStore.project_worktree_lease(entity_id, merged),
         {:ok, _watermark} <- Watermark.advance_local(op) do
      {:ok, merged}
    end
  end

  def project(%Op{entity_type: "handoff", entity_id: entity_id, payload: payload} = op) do
    handoff_payload =
      entity_id
      |> current_handoff_payload()
      |> merge_handoff_payload(normalize_handoff_payload(payload, entity_id))

    with :ok <- Store.put(@handoff_table, entity_id, handoff_payload),
         {:ok, _watermark} <- Watermark.advance_local(op),
         {:ok, handoff} <- HandoffStore.get(entity_id) do
      {:ok, handoff}
    end
  end

  def project(%Op{entity_type: "peer_mailbox", entity_id: entity_id, payload: payload} = op) do
    case payload_value(payload, :messages) do
      messages when is_list(messages) ->
        project_peer_mailbox_snapshot(op, entity_id, payload, messages)

      _other ->
        project_peer_mailbox_delta(op, entity_id, payload)
    end
  end

  def project(%Op{entity_type: entity_type}) do
    {:error, {:unsupported_entity_type, entity_type}}
  end

  @spec rebuild_entity(String.t(), String.t()) ::
          {:ok, HandoffStore.t() | [PeerEnvelope.t()] | [BlackboardEntry.t()] | map()}
          | {:error, term()}
  def rebuild_entity("manifest", entity_id) when is_binary(entity_id) do
    :ok = Store.delete(:mesh_sessions, entity_id)

    case OpLog.list(entity_type: "manifest", entity_id: entity_id) do
      [] ->
        {:error, :not_found}

      ops ->
        with :ok <- replay_ops(ops),
             snapshot when is_map(snapshot) <- MeshStore.get_session(entity_id) do
          {:ok, snapshot}
        else
          nil -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def rebuild_entity("blackboard", entity_id) when is_binary(entity_id) do
    :ok = Store.delete(@blackboard_table, entity_id)

    case OpLog.list(entity_type: "blackboard", entity_id: entity_id) do
      [] ->
        {:error, :not_found}

      ops ->
        with :ok <- replay_ops(ops) do
          {:ok, MeshStore.list_blackboard_entries(entity_id)}
        end
    end
  end

  def rebuild_entity("worktree_lease", entity_id) when is_binary(entity_id) do
    :ok = Store.delete(@worktree_lease_table, entity_id)

    case OpLog.list(entity_type: "worktree_lease", entity_id: entity_id) do
      [] ->
        {:error, :not_found}

      ops ->
        with :ok <- replay_ops(ops),
             {:ok, lease} <- MeshStore.get_worktree_lease(entity_id) do
          {:ok, lease}
        end
    end
  end

  def rebuild_entity("handoff", entity_id) when is_binary(entity_id) do
    :ok = Store.delete(@handoff_table, entity_id)

    case OpLog.list(entity_type: "handoff", entity_id: entity_id) do
      [] ->
        {:error, :not_found}

      ops ->
        with :ok <- replay_ops(ops),
             {:ok, handoff} <- HandoffStore.get(entity_id) do
          {:ok, handoff}
        end
    end
  end

  def rebuild_entity("peer_mailbox", entity_id) when is_binary(entity_id) do
    :ok = Store.delete(@peer_mailbox_table, entity_id)

    case peer_mailbox_ops_for_session(entity_id) do
      [] ->
        {:error, :not_found}

      ops ->
        with :ok <- replay_ops(ops) do
          {:ok, MeshStore.list_peer_messages(entity_id)}
        end
    end
  end

  def rebuild_entity(entity_type, _entity_id),
    do: {:error, {:unsupported_entity_type, entity_type}}

  @spec rebuild_all() :: :ok | {:error, term()}
  def rebuild_all do
    reset_table(:mesh_sessions)
    reset_table(@blackboard_table)
    HandoffStore.reset()
    reset_table(@peer_mailbox_table)
    reset_table(@worktree_lease_table)

    OpLog.list()
    |> replay_ops()
  end

  defp replay_ops(ops) when is_list(ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case project(op) do
        {:ok, _projected} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_handoff_payload(payload, entity_id) when is_map(payload) do
    payload
    |> Map.put_new(:handoff_id, entity_id)
    |> Map.put_new("handoff_id", entity_id)
  end

  defp normalize_handoff_payload(_payload, entity_id) do
    %{handoff_id: entity_id}
  end

  defp current_handoff_payload(entity_id) do
    case Store.get(@handoff_table, entity_id) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp merge_handoff_payload(current, incoming) do
    current = normalize_handoff_payload(current, payload_value(incoming, :handoff_id))
    incoming = normalize_handoff_payload(incoming, payload_value(incoming, :handoff_id))

    %{
      handoff_id: payload_value(incoming, :handoff_id) || payload_value(current, :handoff_id),
      mesh_session_id:
        choose_value(
          payload_value(current, :mesh_session_id),
          payload_value(incoming, :mesh_session_id)
        ),
      agent_id:
        choose_value(payload_value(current, :agent_id), payload_value(incoming, :agent_id)),
      prompt: choose_value(payload_value(current, :prompt), payload_value(incoming, :prompt)),
      queue_mode:
        choose_value(payload_value(current, :queue_mode), payload_value(incoming, :queue_mode)),
      delivery_state:
        choose_delivery_state(
          payload_value(current, :delivery_state),
          payload_value(incoming, :delivery_state)
        ),
      meta: choose_map(payload_value(current, :meta), payload_value(incoming, :meta)),
      run_id: choose_value(payload_value(current, :run_id), payload_value(incoming, :run_id)),
      session_key:
        choose_value(payload_value(current, :session_key), payload_value(incoming, :session_key)),
      message_id:
        choose_value(payload_value(current, :message_id), payload_value(incoming, :message_id)),
      handoff_entry_id:
        choose_value(
          payload_value(current, :handoff_entry_id),
          payload_value(incoming, :handoff_entry_id)
        ),
      delivery_sent_at_ms:
        choose_int(
          payload_value(current, :delivery_sent_at_ms),
          payload_value(incoming, :delivery_sent_at_ms)
        ),
      send_failed_at_ms:
        choose_int(
          payload_value(current, :send_failed_at_ms),
          payload_value(incoming, :send_failed_at_ms)
        ),
      mailbox_persisted_at_ms:
        choose_int(
          payload_value(current, :mailbox_persisted_at_ms),
          payload_value(incoming, :mailbox_persisted_at_ms)
        ),
      blackboard_persisted_at_ms:
        choose_int(
          payload_value(current, :blackboard_persisted_at_ms),
          payload_value(incoming, :blackboard_persisted_at_ms)
        ),
      runtime_accepted_at_ms:
        choose_int(
          payload_value(current, :runtime_accepted_at_ms),
          payload_value(incoming, :runtime_accepted_at_ms)
        ),
      runtime_applied_at_ms:
        choose_int(
          payload_value(current, :runtime_applied_at_ms),
          payload_value(incoming, :runtime_applied_at_ms)
        ),
      completed_at_ms:
        choose_int(
          payload_value(current, :completed_at_ms),
          payload_value(incoming, :completed_at_ms)
        )
    }
  end

  defp choose_value(current, incoming) when incoming in [nil, ""], do: current
  defp choose_value(_current, incoming), do: incoming

  defp choose_int(_current, incoming) when is_integer(incoming), do: incoming
  defp choose_int(current, _incoming), do: current

  defp choose_map(_current, incoming) when is_map(incoming) and map_size(incoming) > 0,
    do: incoming

  defp choose_map(current, _incoming) when is_map(current), do: current
  defp choose_map(_current, _incoming), do: %{}

  defp choose_delivery_state(current, incoming) do
    current = normalize_delivery_state(current)
    incoming = normalize_delivery_state(incoming)

    cond do
      current in [:failed, :completed] ->
        current

      incoming in [:failed, :completed] ->
        incoming

      delivery_state_rank(incoming) >= delivery_state_rank(current) ->
        incoming

      true ->
        current
    end
  end

  defp normalize_delivery_state(value)
       when value in [
              :created,
              :delivery_accepted,
              :mailbox_persisted,
              :blackboard_persisted,
              :runtime_accepted,
              :runtime_applied,
              :completed,
              :failed
            ],
       do: value

  defp normalize_delivery_state(value) when is_binary(value) do
    case value do
      "created" -> :created
      "delivery_accepted" -> :delivery_accepted
      "mailbox_persisted" -> :mailbox_persisted
      "blackboard_persisted" -> :blackboard_persisted
      "runtime_accepted" -> :runtime_accepted
      "runtime_applied" -> :runtime_applied
      "completed" -> :completed
      "failed" -> :failed
      _ -> :created
    end
  end

  defp normalize_delivery_state(_value), do: :created

  defp delivery_state_rank(:created), do: 0
  defp delivery_state_rank(:delivery_accepted), do: 1
  defp delivery_state_rank(:mailbox_persisted), do: 2
  defp delivery_state_rank(:blackboard_persisted), do: 3
  defp delivery_state_rank(:runtime_accepted), do: 4
  defp delivery_state_rank(:runtime_applied), do: 5
  defp delivery_state_rank(:completed), do: 6
  defp delivery_state_rank(:failed), do: 6

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp normalize_session_snapshot(payload, entity_id) when is_map(payload) do
    %{
      session_id: payload_value(payload, :session_id) || entity_id,
      goal: payload_value(payload, :goal),
      roles: payload_value(payload, :roles) || [],
      peer_graph: payload_value(payload, :peer_graph) || %{},
      shared_files: payload_value(payload, :shared_files) || [],
      memory_scopes: payload_value(payload, :memory_scopes) || [],
      delivery_semantics: payload_value(payload, :delivery_semantics) || "at_least_once",
      metadata: payload_value(payload, :metadata) || %{},
      status: payload_value(payload, :status) || :active,
      blackboard_size: payload_value(payload, :blackboard_size) || 0,
      inserted_at_ms: payload_value(payload, :inserted_at_ms) || System.system_time(:millisecond),
      updated_at_ms: payload_value(payload, :updated_at_ms) || System.system_time(:millisecond)
    }
  end

  defp current_blackboard_entries(session_id) do
    case Store.get(@blackboard_table, session_id) do
      payload when is_list(payload) -> Enum.map(payload, &BlackboardEntry.from_map/1)
      _ -> []
    end
  end

  defp merge_blackboard_entry(entries, %BlackboardEntry{} = incoming) do
    if Enum.any?(entries, &(&1.entry_id == incoming.entry_id)) do
      entries
    else
      (entries ++ [incoming])
      |> Enum.sort_by(&{&1.inserted_at_ms, &1.entry_id}, :asc)
    end
  end

  defp current_worktree_lease(slice_key) do
    case Store.get(@worktree_lease_table, slice_key) do
      payload when is_map(payload) -> WorktreeLease.new(payload)
      _ -> nil
    end
  end

  defp merge_worktree_lease(nil, %WorktreeLease{} = incoming, _op_type), do: incoming

  defp merge_worktree_lease(%WorktreeLease{} = current, %WorktreeLease{} = incoming, "lease_released") do
    if current.lease_epoch == incoming.lease_epoch and
         current.origin_node_id == incoming.origin_node_id do
      %{current | released_at_ms: incoming.released_at_ms || current.released_at_ms}
    else
      current
    end
  end

  defp merge_worktree_lease(%WorktreeLease{} = current, %WorktreeLease{} = incoming, _op_type) do
    if worktree_lease_winner?(incoming, current) do
      %{incoming | released_at_ms: nil}
    else
      current
    end
  end

  defp worktree_lease_winner?(incoming, current) do
    cond do
      incoming.lease_epoch > current.lease_epoch ->
        true

      incoming.lease_epoch < current.lease_epoch ->
        false

      true ->
        normalize_origin_node_id(incoming.origin_node_id) <
          normalize_origin_node_id(current.origin_node_id)
    end
  end

  defp normalize_origin_node_id(value) when is_binary(value), do: value
  defp normalize_origin_node_id(_value), do: "~"

  defp normalize_peer_mailbox_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(&PeerEnvelope.from_map/1)
    |> Enum.sort_by(& &1.inserted_at_ms, :asc)
  end

  defp normalize_peer_mailbox_messages(_messages), do: []

  defp project_peer_mailbox_snapshot(op, entity_id, payload, messages) do
    session_id = payload_value(payload, :session_id) || entity_id
    normalized_messages = normalize_peer_mailbox_messages(messages)

    with true <- is_binary(session_id) and session_id != "",
         :ok <-
           Store.put(
             @peer_mailbox_table,
             session_id,
             Enum.map(normalized_messages, &PeerEnvelope.to_map/1)
           ),
         {:ok, _watermark} <- Watermark.advance_local(op) do
      {:ok, normalized_messages}
    else
      false -> {:error, :invalid_peer_mailbox_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_peer_mailbox_delta(
         %Op{op_type: op_type, payload: payload} = op,
         entity_id,
         _raw_payload
       ) do
    session_id = payload_value(payload, :session_id)
    incoming = PeerEnvelope.from_map(Map.put_new(payload, :message_id, entity_id))

    with true <- is_binary(session_id) and session_id != "",
         updated_messages <-
           merge_peer_mailbox_delta(current_peer_mailbox_messages(session_id), incoming, op_type),
         :ok <-
           Store.put(
             @peer_mailbox_table,
             session_id,
             Enum.map(updated_messages, &PeerEnvelope.to_map/1)
           ),
         {:ok, _watermark} <- Watermark.advance_local(op) do
      {:ok, updated_messages}
    else
      false -> {:error, :invalid_peer_mailbox_delta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_peer_mailbox_messages(session_id) do
    case Store.get(@peer_mailbox_table, session_id) do
      payload when is_list(payload) -> Enum.map(payload, &PeerEnvelope.from_map/1)
      _ -> []
    end
  end

  defp merge_peer_mailbox_delta(messages, incoming, op_type) do
    case split_peer_message(messages, incoming.message_id) do
      {:ok, current, others} ->
        merged = merge_peer_message(current, incoming, op_type)
        insert_peer_message(others, merged)

      :error ->
        insert_peer_message(messages, incoming)
    end
  end

  defp merge_peer_message(current, incoming, "message_created") do
    %{
      incoming
      | claimed_at_ms: choose_peer_value(current.claimed_at_ms, incoming.claimed_at_ms),
        claim_expires_at_ms:
          choose_peer_value(current.claim_expires_at_ms, incoming.claim_expires_at_ms),
        claimed_by: choose_peer_value(current.claimed_by, incoming.claimed_by),
        lease_epoch: max(current.lease_epoch || 0, incoming.lease_epoch || 0),
        acknowledged_at_ms:
          choose_peer_value(current.acknowledged_at_ms, incoming.acknowledged_at_ms),
        acknowledged_by: choose_peer_value(current.acknowledged_by, incoming.acknowledged_by),
        metadata: Map.merge(incoming.metadata || %{}, current.metadata || %{})
    }
  end

  defp merge_peer_message(current, incoming, "message_claimed") do
    cond do
      not is_nil(current.acknowledged_at_ms) ->
        current

      incoming.lease_epoch > current.lease_epoch ->
        %{incoming | acknowledged_at_ms: nil, acknowledged_by: nil}

      incoming.lease_epoch < current.lease_epoch ->
        current

      claim_origin_node_id(incoming) < claim_origin_node_id(current) ->
        %{incoming | acknowledged_at_ms: nil, acknowledged_by: nil}

      true ->
        current
    end
  end

  defp merge_peer_message(current, incoming, "message_acked") do
    cond do
      is_nil(current.acknowledged_at_ms) and incoming.lease_epoch == current.lease_epoch ->
        %{
          current
          | acknowledged_at_ms: incoming.acknowledged_at_ms,
            acknowledged_by: incoming.acknowledged_by
        }

      incoming.lease_epoch > current.lease_epoch ->
        incoming

      true ->
        current
    end
  end

  defp merge_peer_message(_current, incoming, _op_type), do: incoming

  defp choose_peer_value(current, incoming) when incoming in [nil, ""], do: current
  defp choose_peer_value(_current, incoming), do: incoming

  defp insert_peer_message(messages, envelope) do
    (messages ++ [envelope])
    |> Enum.sort_by(& &1.inserted_at_ms, :asc)
  end

  defp split_peer_message(envelopes, message_id) do
    case Enum.split_with(envelopes, &(&1.message_id != message_id)) do
      {others, [envelope | rest]} -> {:ok, envelope, others ++ rest}
      {_others, []} -> :error
    end
  end

  defp claim_origin_node_id(%PeerEnvelope{} = envelope) do
    metadata = envelope.metadata || %{}
    Map.get(metadata, "_claim_origin_node_id") || Map.get(metadata, :_claim_origin_node_id) || "~"
  end

  defp peer_mailbox_ops_for_session(session_id) do
    OpLog.list(entity_type: "peer_mailbox")
    |> Enum.filter(fn op -> payload_value(op.payload, :session_id) == session_id end)
  end

  defp reset_table(table) do
    for {stored_key, _value} <- Store.list(table) do
      Store.delete(table, stored_key)
    end

    :ok
  end
end
