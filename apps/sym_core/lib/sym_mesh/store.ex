defmodule LemonMesh.Store do
  @moduledoc false

  require Logger

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{BlackboardEntry, Manifest, NodeIdentity, OpLog, PeerEnvelope, WorktreeLease}
  alias LemonMesh.Replication.Projector

  @session_table :mesh_sessions
  @blackboard_table :mesh_blackboards
  @peer_mailbox_table :mesh_peer_mailboxes
  @peer_mailbox_lock_table :mesh_peer_mailbox_locks
  @worktree_lease_table :mesh_worktree_leases

  @spec upsert_session(Manifest.t(), keyword()) :: :ok | {:error, term()}
  def upsert_session(%Manifest{} = manifest, opts \\ []) do
    manifest
    |> session_snapshot_from_manifest(opts)
    |> authoritative_session_upsert()
  end

  @spec put_session(Manifest.t(), keyword()) :: :ok | {:error, term()}
  def put_session(%Manifest{} = manifest, opts \\ []) do
    manifest
    |> session_snapshot_from_manifest(opts)
    |> project_session_snapshot()
  end

  @spec put_session_snapshot(map()) :: :ok | {:error, term()}
  def put_session_snapshot(%{session_id: session_id} = snapshot) when is_binary(session_id) do
    project_session_snapshot(snapshot)
  end

  @spec get_session(String.t()) :: map() | nil
  def get_session(session_id) when is_binary(session_id) do
    case CoreStore.get(@session_table, session_id) do
      nil -> nil
      snapshot when is_map(snapshot) -> normalize_session_snapshot(snapshot)
    end
  end

  @spec list_sessions() :: [map()]
  def list_sessions do
    @session_table
    |> CoreStore.list()
    |> Enum.map(fn {_session_id, snapshot} -> normalize_session_snapshot(snapshot) end)
  end

  @spec put_blackboard_entries(String.t(), [BlackboardEntry.t()]) :: :ok | {:error, term()}
  def put_blackboard_entries(session_id, entries)
      when is_binary(session_id) and is_list(entries) do
    project_blackboard_entries(session_id, entries)
  end

  @spec project_blackboard_entries(String.t(), [BlackboardEntry.t()]) :: :ok | {:error, term()}
  def project_blackboard_entries(session_id, entries)
      when is_binary(session_id) and is_list(entries) do
    payload = Enum.map(entries, &BlackboardEntry.to_map/1)
    CoreStore.put(@blackboard_table, session_id, payload)
  end

  @spec list_blackboard_entries(String.t()) :: [BlackboardEntry.t()]
  def list_blackboard_entries(session_id) when is_binary(session_id) do
    case CoreStore.get(@blackboard_table, session_id) do
      nil -> []
      payload when is_list(payload) -> Enum.map(payload, &BlackboardEntry.from_map/1)
    end
  end

  @spec append_blackboard_entry(String.t(), keyword() | map()) ::
          {:ok, BlackboardEntry.t()} | {:error, :not_found | term()}
  def append_blackboard_entry(session_id, attrs) when is_binary(session_id) do
    case get_session(session_id) do
      nil ->
        {:error, :not_found}

      _snapshot ->
        entry = BlackboardEntry.new(session_id, attrs)
        updated_at_ms = entry.inserted_at_ms

        case authoritative_blackboard_append(entry) do
          {:ok, entries} ->
            refresh_session_metadata_best_effort(session_id, %{
              blackboard_size: length(entries),
              updated_at_ms: updated_at_ms
            })

            {:ok, entry}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec put_peer_messages(String.t(), [PeerEnvelope.t()]) :: :ok | {:error, term()}
  def put_peer_messages(session_id, envelopes)
      when is_binary(session_id) and is_list(envelopes) do
    payload = Enum.map(envelopes, &PeerEnvelope.to_map/1)
    CoreStore.put(@peer_mailbox_table, session_id, payload)
  end

  @spec list_peer_messages(String.t()) :: [PeerEnvelope.t()]
  def list_peer_messages(session_id) when is_binary(session_id) do
    case CoreStore.get(@peer_mailbox_table, session_id) do
      nil -> []
      payload when is_list(payload) -> Enum.map(payload, &PeerEnvelope.from_map/1)
    end
  end

  @spec claim_peer_messages(String.t(), keyword() | map()) ::
          {:ok, [PeerEnvelope.t()]} | {:error, :not_found}
  def claim_peer_messages(session_id, opts) when is_binary(session_id) do
    case get_session(session_id) do
      nil ->
        {:error, :not_found}

      _snapshot ->
        with_mailbox_lock(session_id, fn ->
          opts = normalize_map(opts)
          now_ms = System.system_time(:millisecond)
          limit = normalize_limit(Map.get(opts, :limit) || Map.get(opts, "limit"))

          with {:ok, envelopes} <- load_peer_messages_for_update(session_id) do
            {updated_envelopes, claimed} =
              claim_available_messages(envelopes, opts, now_ms, limit)

            case claimed do
              [] ->
                {:ok, []}

              [first | _rest] ->
                claimed_ids = MapSet.new(Enum.map(claimed, & &1.message_id))

                claimed_envelopes =
                  updated_envelopes
                  |> Enum.filter(&MapSet.member?(claimed_ids, &1.message_id))
                  |> Enum.map(&with_claim_origin_node_id(&1, NodeIdentity.current_node_id()))

                case append_peer_message_ops(claimed_envelopes, "message_claimed") do
                  :ok ->
                    refresh_session_metadata_best_effort(session_id, %{
                      updated_at_ms: first.claimed_at_ms || now_ms
                    })

                    {:ok, claimed}

                  {:error, reason} ->
                    {:error, reason}
                end
            end
          end
        end)
    end
  end

  @spec send_peer_message(String.t(), keyword() | map()) ::
          {:ok, PeerEnvelope.t()} | {:error, :not_found}
  def send_peer_message(session_id, attrs) when is_binary(session_id) do
    case get_session(session_id) do
      nil ->
        {:error, :not_found}

      _snapshot ->
        with_mailbox_lock(session_id, fn ->
          with {:ok, envelopes} <- load_peer_messages_for_update(session_id) do
            envelope =
              attrs
              |> normalize_map()
              |> Map.put(:session_id, session_id)
              |> PeerEnvelope.new()

            case find_peer_message_by_dedupe(envelopes, envelope.dedupe_key) do
              nil ->
                case append_peer_message_op(envelope, "message_created") do
                  :ok ->
                    refresh_session_metadata_best_effort(session_id, %{
                      updated_at_ms: envelope.inserted_at_ms
                    })

                    {:ok, envelope}

                  {:error, reason} ->
                    {:error, reason}
                end

              existing ->
                {:ok, existing}
            end
          end
        end)
    end
  end

  @spec ack_peer_message(String.t(), String.t(), keyword() | map()) ::
          {:ok, PeerEnvelope.t()} | {:error, :not_found | :message_not_found}
  def ack_peer_message(session_id, message_id, attrs)
      when is_binary(session_id) and is_binary(message_id) do
    case get_session(session_id) do
      nil ->
        {:error, :not_found}

      _snapshot ->
        with_mailbox_lock(session_id, fn ->
          attrs = normalize_map(attrs)

          expected_to_agent =
            Map.get(attrs, :expected_to_agent) || Map.get(attrs, "expected_to_agent")

          expected_claimed_by =
            Map.get(attrs, :expected_claimed_by) || Map.get(attrs, "expected_claimed_by")

          with {:ok, envelopes} <- load_peer_messages_for_update(session_id) do
            case split_peer_message(envelopes, message_id) do
              :error ->
                {:error, :message_not_found}

              {:ok, envelope, _others} ->
                if (is_binary(expected_to_agent) and envelope.to_agent != expected_to_agent) or
                     (is_binary(expected_claimed_by) and
                        envelope.claimed_by != expected_claimed_by) do
                  {:error, :message_not_found}
                else
                  acknowledged = PeerEnvelope.acknowledge(envelope, attrs)

                  case append_peer_message_op(acknowledged, "message_acked") do
                    :ok ->
                      refresh_session_metadata_best_effort(session_id, %{
                        updated_at_ms: acknowledged.acknowledged_at_ms
                      })

                      {:ok, acknowledged}

                    {:error, reason} ->
                      {:error, reason}
                  end
                end
            end
          end
        end)
    end
  end

  @spec get_worktree_lease(String.t()) :: {:ok, WorktreeLease.t()} | {:error, :not_found}
  def get_worktree_lease(slice_key) when is_binary(slice_key) do
    case CoreStore.get(@worktree_lease_table, slice_key) do
      payload when is_map(payload) -> {:ok, WorktreeLease.new(payload)}
      _ -> {:error, :not_found}
    end
  end

  @spec list_worktree_leases() :: [WorktreeLease.t()]
  def list_worktree_leases do
    @worktree_lease_table
    |> CoreStore.list()
    |> Enum.map(fn {_slice_key, payload} -> WorktreeLease.new(payload) end)
  end

  @spec project_worktree_lease(String.t(), WorktreeLease.t()) :: :ok | {:error, term()}
  def project_worktree_lease(slice_key, %WorktreeLease{} = lease) when is_binary(slice_key) do
    CoreStore.put(@worktree_lease_table, slice_key, Map.from_struct(lease))
  end

  @spec record_worktree_lease(String.t(), String.t(), map() | keyword()) ::
          {:ok, WorktreeLease.t()} | {:error, term()}
  def record_worktree_lease(slice_key, op_type, attrs)
      when is_binary(slice_key) and is_binary(op_type) do
    attrs = normalize_map(attrs)
    origin_node_id = Map.get(attrs, :origin_node_id) || Map.get(attrs, "origin_node_id") ||
      NodeIdentity.current_node_id()

    payload =
      attrs
      |> Map.put(:origin_node_id, origin_node_id)
      |> maybe_put_worktree_release_timestamp(op_type)

    lease_epoch = Map.get(payload, :lease_epoch) || Map.get(payload, "lease_epoch") || 0

    case OpLog.append(%{
           op_id: worktree_lease_op_id(slice_key, op_type, lease_epoch, origin_node_id),
           origin_node_id: origin_node_id,
           entity_type: "worktree_lease",
           entity_id: slice_key,
           op_type: op_type,
           lease_epoch: lease_epoch,
           payload: payload
         }) do
      {:ok, op} ->
        Projector.project(op)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reset() :: :ok
  def reset do
    delete_table(@session_table)
    delete_table(@blackboard_table)
    delete_table(@peer_mailbox_table)
    delete_table(@worktree_lease_table)
    :ok
  end

  defp delete_table(table) do
    for {key, _value} <- CoreStore.list(table) do
      CoreStore.delete(table, key)
    end
  end

  defp normalize_session_snapshot(snapshot) do
    %{
      session_id: fetch(snapshot, :session_id),
      goal: fetch(snapshot, :goal),
      roles: fetch(snapshot, :roles) || [],
      peer_graph: fetch(snapshot, :peer_graph) || %{},
      shared_files: fetch(snapshot, :shared_files) || [],
      memory_scopes: fetch(snapshot, :memory_scopes) || [],
      delivery_semantics: fetch(snapshot, :delivery_semantics) || "at_least_once",
      metadata: fetch(snapshot, :metadata) || %{},
      status: normalize_status(fetch(snapshot, :status)),
      blackboard_size: fetch(snapshot, :blackboard_size) || 0,
      inserted_at_ms: fetch(snapshot, :inserted_at_ms) || System.system_time(:millisecond),
      updated_at_ms: fetch(snapshot, :updated_at_ms) || System.system_time(:millisecond)
    }
  end

  @spec project_session_snapshot(map()) :: :ok | {:error, term()}
  def project_session_snapshot(%{session_id: session_id} = snapshot) when is_binary(session_id) do
    CoreStore.put(@session_table, session_id, normalize_session_snapshot(snapshot))
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("active"), do: :active
  defp normalize_status("stopped"), do: :stopped
  defp normalize_status("crashed"), do: :crashed
  defp normalize_status(_status), do: :active

  defp normalize_embedded_map(%_{} = value), do: Map.from_struct(value)
  defp normalize_embedded_map(value), do: value

  defp refresh_session_metadata_best_effort(session_id, updates)
       when is_binary(session_id) and is_map(updates) do
    case CoreStore.update(@session_table, session_id, fn current_snapshot ->
           case current_snapshot do
             snapshot when is_map(snapshot) ->
               next_snapshot =
                 snapshot
                 |> normalize_session_snapshot()
                 |> Map.merge(updates)

               {:ok, next_snapshot, :ok}

             _other ->
               {:error, :not_found}
           end
         end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Mesh session metadata refresh failed session_id=#{session_id} updates=#{inspect(updates)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp claim_available_messages(envelopes, opts, now_ms, limit) do
    Enum.map_reduce(envelopes, limit, fn envelope, remaining ->
      if claimable?(envelope, opts, now_ms, remaining) do
        claimed =
          PeerEnvelope.claim(envelope,
            claimed_by: Map.get(opts, :claimed_by) || Map.get(opts, "claimed_by"),
            lease_ms: Map.get(opts, :lease_ms) || Map.get(opts, "lease_ms"),
            claimed_at_ms: now_ms
          )

        {claimed, remaining - 1}
      else
        {envelope, remaining}
      end
    end)
    |> then(fn {updated_envelopes, _remaining} ->
      claimed =
        Enum.filter(updated_envelopes, fn envelope ->
          envelope.claimed_at_ms == now_ms and
            envelope.claimed_by == (Map.get(opts, :claimed_by) || Map.get(opts, "claimed_by"))
        end)

      {updated_envelopes, claimed}
    end)
  end

  defp claimable?(_envelope, _opts, _now_ms, remaining) when remaining <= 0, do: false

  defp claimable?(envelope, opts, now_ms, remaining) when remaining > 0 do
    is_nil(envelope.acknowledged_at_ms) and
      not PeerEnvelope.claim_active?(envelope, now_ms) and
      matches_filter?(envelope.to_agent, Map.get(opts, :to_agent) || Map.get(opts, "to_agent")) and
      matches_filter?(
        envelope.from_agent,
        Map.get(opts, :from_agent) || Map.get(opts, "from_agent")
      ) and
      matches_filter?(envelope.channel, Map.get(opts, :channel) || Map.get(opts, "channel")) and
      matches_filter?(
        envelope.payload_kind,
        Map.get(opts, :payload_kind) || Map.get(opts, "payload_kind")
      )
  end

  defp split_peer_message(envelopes, message_id) do
    case Enum.split_with(envelopes, &(&1.message_id != message_id)) do
      {others, [envelope | rest]} -> {:ok, envelope, others ++ rest}
      {_others, []} -> :error
    end
  end

  defp matches_filter?(_value, nil), do: true
  defp matches_filter?(value, filter), do: value == filter

  defp find_peer_message_by_dedupe(_envelopes, nil), do: nil
  defp find_peer_message_by_dedupe(_envelopes, ""), do: nil

  defp find_peer_message_by_dedupe(envelopes, dedupe_key) do
    Enum.find(envelopes, &(&1.dedupe_key == dedupe_key))
  end

  defp normalize_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_limit(_limit), do: 1_000_000

  defp normalize_map(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_map(attrs) when is_map(attrs), do: attrs
  defp normalize_map(_attrs), do: %{}

  defp load_peer_messages_for_update(session_id) do
    case CoreStore.get(@peer_mailbox_table, session_id) do
      payload when is_list(payload) ->
        {:ok, Enum.map(payload, &PeerEnvelope.from_map/1)}

      nil ->
        case peer_mailbox_ops_exist?(session_id) do
          false -> {:ok, []}
          true -> {:error, :projection_missing}
        end
    end
  end

  defp peer_mailbox_ops_exist?(session_id) when is_binary(session_id) do
    case OpLog.list(entity_type: "peer_mailbox") do
      [] -> false
      ops -> Enum.any?(ops, &(fetch(&1.payload, :session_id) == session_id))
    end
  end

  defp append_peer_message_ops(envelopes, op_type) when is_list(envelopes) do
    Enum.reduce_while(envelopes, :ok, fn envelope, :ok ->
      case append_peer_message_op(envelope, op_type) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_peer_message_op(%PeerEnvelope{} = envelope, op_type) do
    case OpLog.append(%{
           op_id: peer_mailbox_op_id(envelope, op_type),
           entity_type: "peer_mailbox",
           entity_id: envelope.message_id,
           op_type: op_type,
           lease_epoch: envelope.lease_epoch,
           payload: PeerEnvelope.to_map(envelope)
         }) do
      {:ok, op} ->
        case Projector.project(op) do
          {:ok, _messages} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_mailbox_lock(session_id, fun) when is_binary(session_id) and is_function(fun, 0) do
    ensure_peer_mailbox_lock_table!()
    acquire_peer_mailbox_lock(session_id)

    try do
      fun.()
    after
      release_peer_mailbox_lock(session_id)
    end
  end

  defp with_claim_origin_node_id(%PeerEnvelope{} = envelope, node_id) when is_binary(node_id) do
    metadata =
      envelope.metadata
      |> Kernel.||(%{})
      |> Map.put("_claim_origin_node_id", node_id)

    %{envelope | metadata: metadata}
  end

  defp peer_mailbox_op_id(%PeerEnvelope{} = envelope, "message_created") do
    "#{envelope.message_id}:message_created"
  end

  defp peer_mailbox_op_id(%PeerEnvelope{} = envelope, "message_claimed") do
    "#{envelope.message_id}:message_claimed:#{envelope.lease_epoch}"
  end

  defp peer_mailbox_op_id(%PeerEnvelope{} = envelope, "message_acked") do
    "#{envelope.message_id}:message_acked:#{envelope.lease_epoch}"
  end

  defp ensure_peer_mailbox_lock_table! do
    case :ets.whereis(@peer_mailbox_lock_table) do
      :undefined ->
        try do
          :ets.new(@peer_mailbox_lock_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @peer_mailbox_lock_table
        end

      _table ->
        @peer_mailbox_lock_table
    end

    :ok
  end

  defp acquire_peer_mailbox_lock(session_id) do
    ensure_peer_mailbox_lock_table!()

    case :ets.insert_new(@peer_mailbox_lock_table, {session_id, self()}) do
      true ->
        :ok

      false ->
        Process.sleep(1)
        acquire_peer_mailbox_lock(session_id)
    end
  rescue
    ArgumentError ->
      Process.sleep(1)
      acquire_peer_mailbox_lock(session_id)
  end

  defp release_peer_mailbox_lock(session_id) do
    case :ets.whereis(@peer_mailbox_lock_table) do
      :undefined ->
        :ok

      _table ->
        case :ets.lookup(@peer_mailbox_lock_table, session_id) do
          [{^session_id, owner}] when owner == self() ->
            :ets.delete(@peer_mailbox_lock_table, session_id)
            :ok

          _other ->
            :ok
        end
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp session_snapshot_from_manifest(%Manifest{} = manifest, opts) do
    %{
      session_id: manifest.session_id,
      goal: manifest.goal,
      roles: manifest.roles,
      peer_graph: manifest.peer_graph,
      shared_files: Enum.map(manifest.shared_files, &normalize_embedded_map/1),
      memory_scopes: manifest.memory_scopes,
      delivery_semantics: manifest.delivery_semantics,
      metadata: manifest.metadata,
      status: Keyword.get(opts, :status, :active),
      blackboard_size: Keyword.get(opts, :blackboard_size, 0),
      inserted_at_ms: manifest.inserted_at_ms,
      updated_at_ms: Keyword.get(opts, :updated_at_ms, System.system_time(:millisecond))
    }
  end

  defp authoritative_session_upsert(snapshot) do
    normalized_snapshot = normalize_session_snapshot(snapshot)

    case OpLog.append(%{
           op_id: manifest_op_id(normalized_snapshot),
           entity_type: "manifest",
           entity_id: normalized_snapshot.session_id,
           op_type: "manifest_upserted",
           payload: normalized_snapshot
         }) do
      {:ok, op} ->
        case Projector.project(op) do
          {:ok, _snapshot} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authoritative_blackboard_append(%BlackboardEntry{} = entry) do
    case OpLog.append(%{
           op_id: "#{entry.entry_id}:entry_appended",
           entity_type: "blackboard",
           entity_id: entry.session_id,
           op_type: "entry_appended",
           payload: BlackboardEntry.to_map(entry)
         }) do
      {:ok, op} ->
        Projector.project(op)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp manifest_op_id(snapshot) do
    digest =
      snapshot
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{snapshot.session_id}:manifest_upserted:#{snapshot.updated_at_ms}:#{digest}"
  end

  defp worktree_lease_op_id(slice_key, op_type, lease_epoch, origin_node_id) do
    "#{slice_key}:#{op_type}:#{lease_epoch}:#{origin_node_id}"
  end

  defp maybe_put_worktree_release_timestamp(payload, "lease_released") do
    Map.put_new(payload, :released_at_ms, System.system_time(:millisecond))
  end

  defp maybe_put_worktree_release_timestamp(payload, _op_type), do: payload
end
