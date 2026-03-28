defmodule LemonMesh do
  @moduledoc """
  Public facade for the absorbed mesh/durable-runtime subsystem inside
  `:lemon_core`.

  `LemonMesh.*` remains the public module namespace for mesh session
  orchestration and shared blackboard state, but it is no longer a standalone
  umbrella app. The implementation lives under `apps/lemon_core/lib/lemon_mesh/`.

  This first slice intentionally stays BEAM-local:

  - mesh sessions run as supervised GenServers
  - active sessions are discoverable via a Registry
  - manifest snapshots and blackboard entries persist through `LemonCore.Store`
  """

  alias LemonMesh.{PeerEnvelope, Session, SessionRegistry, SessionSupervisor, Store}

  @type session_snapshot :: %{
          session_id: String.t(),
          goal: String.t() | nil,
          roles: [String.t()],
          peer_graph: map(),
          shared_files: [map()],
          memory_scopes: [String.t()],
          delivery_semantics: String.t(),
          metadata: map(),
          status: atom(),
          blackboard_size: non_neg_integer(),
          inserted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer()
        }

  @spec start_session(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def start_session(attrs \\ %{}) do
    SessionSupervisor.start_session(attrs)
  end

  @spec session_id(pid()) :: String.t()
  def session_id(pid) when is_pid(pid) do
    Session.session_id(pid)
  end

  @spec session_pid(String.t()) :: {:ok, pid()} | :error
  def session_pid(session_id) when is_binary(session_id) do
    SessionRegistry.lookup(session_id)
  end

  @spec get_session(String.t()) :: {:ok, session_snapshot()} | {:error, :not_found}
  def get_session(session_id) when is_binary(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} ->
        {:ok, Session.snapshot(pid)}

      :error ->
        case Store.get_session(session_id) do
          nil -> {:error, :not_found}
          snapshot -> {:ok, snapshot}
        end
    end
  end

  @spec get_session!(String.t()) :: session_snapshot()
  def get_session!(session_id) when is_binary(session_id) do
    case get_session(session_id) do
      {:ok, snapshot} -> snapshot
      {:error, :not_found} -> raise ArgumentError, "mesh session not found: #{session_id}"
    end
  end

  @spec list_sessions() :: [session_snapshot()]
  def list_sessions do
    active =
      SessionSupervisor.list_sessions()
      |> Enum.map(&Session.snapshot/1)
      |> Map.new(fn snapshot -> {snapshot.session_id, snapshot} end)

    persisted =
      Store.list_sessions()
      |> Enum.reduce(active, fn snapshot, acc ->
        Map.put_new(acc, snapshot.session_id, snapshot)
      end)

    persisted
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at_ms, :desc)
  end

  @spec get_manifest(String.t()) :: {:ok, LemonMesh.Manifest.t()} | {:error, :not_found}
  def get_manifest(session_id) when is_binary(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} ->
        {:ok, Session.manifest(pid)}

      :error ->
        case Store.get_session(session_id) do
          nil -> {:error, :not_found}
          snapshot -> {:ok, LemonMesh.Manifest.new(snapshot)}
        end
    end
  end

  @spec append_blackboard_entry(String.t(), keyword() | map()) ::
          {:ok, LemonMesh.BlackboardEntry.t()} | {:error, :not_found}
  def append_blackboard_entry(session_id, attrs) when is_binary(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} -> Session.append_blackboard_entry(pid, attrs)
      :error -> Store.append_blackboard_entry(session_id, attrs)
    end
  end

  @spec list_blackboard_entries(String.t()) ::
          {:ok, [LemonMesh.BlackboardEntry.t()]} | {:error, :not_found}
  def list_blackboard_entries(session_id) when is_binary(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} ->
        {:ok, Session.list_blackboard(pid)}

      :error ->
        case Store.get_session(session_id) do
          nil -> {:error, :not_found}
          _snapshot -> {:ok, Store.list_blackboard_entries(session_id)}
      end
    end
  end

  @spec send_peer_message(String.t(), keyword() | map()) ::
          {:ok, PeerEnvelope.t()} | {:error, :not_found}
  def send_peer_message(session_id, attrs) when is_binary(session_id) do
    Store.send_peer_message(session_id, attrs)
  end

  @spec claim_peer_messages(String.t(), keyword()) ::
          {:ok, [PeerEnvelope.t()]} | {:error, :not_found}
  def claim_peer_messages(session_id, opts \\ []) when is_binary(session_id) do
    Store.claim_peer_messages(session_id, opts)
  end

  @spec list_peer_messages(String.t(), keyword()) ::
          {:ok, [PeerEnvelope.t()]} | {:error, :not_found}
  def list_peer_messages(session_id, opts \\ []) when is_binary(session_id) do
    case Store.get_session(session_id) do
      nil ->
        {:error, :not_found}

      _snapshot ->
        messages =
          session_id
          |> Store.list_peer_messages()
          |> maybe_filter_peer_messages(:to_agent, Keyword.get(opts, :to_agent))
          |> maybe_filter_peer_messages(:from_agent, Keyword.get(opts, :from_agent))
          |> maybe_filter_peer_messages(:channel, Keyword.get(opts, :channel))
          |> maybe_filter_pending(Keyword.get(opts, :pending_only, true))
          |> maybe_take(Keyword.get(opts, :limit))

        {:ok, messages}
    end
  end

  @spec ack_peer_message(String.t(), String.t(), keyword() | map()) ::
          {:ok, PeerEnvelope.t()} | {:error, :not_found | :message_not_found}
  def ack_peer_message(session_id, message_id, attrs \\ %{})
      when is_binary(session_id) and is_binary(message_id) do
    Store.ack_peer_message(session_id, message_id, attrs)
  end

  defp maybe_filter_peer_messages(messages, _field, nil), do: messages

  defp maybe_filter_peer_messages(messages, field, value) do
    Enum.filter(messages, fn message ->
      Map.get(message, field) == value
    end)
  end

  defp maybe_filter_pending(messages, true) do
    now_ms = System.system_time(:millisecond)

    Enum.filter(messages, fn message ->
      is_nil(message.acknowledged_at_ms) and not PeerEnvelope.claim_active?(message, now_ms)
    end)
  end

  defp maybe_filter_pending(messages, _include_all), do: messages

  defp maybe_take(items, limit) when is_integer(limit) and limit >= 0, do: Enum.take(items, limit)
  defp maybe_take(items, _limit), do: items
end
