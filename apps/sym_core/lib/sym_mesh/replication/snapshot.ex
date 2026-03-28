defmodule LemonMesh.Replication.Snapshot do
  @moduledoc false

  alias LemonCore.Store
  alias LemonMesh.Replication.Watermark

  @spec current(String.t()) :: {:ok, map()} | {:error, term()}
  def current("mesh_state") do
    {:ok,
     %{
       "scope" => "mesh_state",
       "generatedAtMs" => System.system_time(:millisecond),
       "watermark" => Watermark.local(),
       "entities" => %{
         "sessions" => Enum.map(LemonMesh.Store.list_sessions(), &normalize_map/1),
         "blackboards" => blackboards_snapshot(),
         "peerMailboxes" => peer_mailboxes_snapshot(),
         "handoffs" => handoffs_snapshot()
       }
     }}
  end

  def current(scope), do: {:error, {:unsupported_scope, scope}}

  @spec authority_state_empty?() :: boolean()
  def authority_state_empty? do
    LemonMesh.Store.list_sessions() == [] and
      Store.list(:mesh_blackboards) == [] and
      Store.list(:mesh_peer_mailboxes) == [] and
      Store.list(:mesh_handoff_ops) == [] and
      Store.list(:mesh_op_log) == []
  end

  @spec install_if_empty(map()) :: {:installed, map()} | {:skipped_nonempty} | {:error, term()}
  def install_if_empty(snapshot) when is_map(snapshot) do
    if authority_state_empty?() do
      case install(snapshot) do
        :ok -> {:installed, snapshot}
        {:error, reason} -> {:error, reason}
      end
    else
      {:skipped_nonempty}
    end
  end

  @spec install(map()) :: :ok | {:error, term()}
  def install(%{"scope" => "mesh_state", "entities" => entities}) when is_map(entities) do
    install_sessions(Map.get(entities, "sessions", []))
    install_blackboards(Map.get(entities, "blackboards", []))
    install_peer_mailboxes(Map.get(entities, "peerMailboxes", []))
    install_handoffs(Map.get(entities, "handoffs", []))
    :ok
  end

  def install(%{"scope" => scope}), do: {:error, {:unsupported_scope, scope}}
  def install(_snapshot), do: {:error, :invalid_snapshot}

  defp blackboards_snapshot do
    Store.list(:mesh_blackboards)
    |> Enum.map(fn {session_id, entries} ->
      %{"sessionId" => session_id, "entries" => entries}
    end)
  end

  defp peer_mailboxes_snapshot do
    Store.list(:mesh_peer_mailboxes)
    |> Enum.map(fn {session_id, messages} ->
      %{"sessionId" => session_id, "messages" => messages}
    end)
  end

  defp handoffs_snapshot do
    Store.list(:mesh_handoff_ops)
    |> Enum.map(fn {_handoff_id, payload} -> payload end)
  end

  defp install_sessions(snapshots) when is_list(snapshots) do
    Enum.each(snapshots, fn snapshot ->
      LemonMesh.Store.put_session_snapshot(normalize_map(snapshot))
    end)
  end

  defp install_blackboards(entries) when is_list(entries) do
    Enum.each(entries, fn entry ->
      payload = normalize_map(entry)

      Store.put(
        :mesh_blackboards,
        payload["sessionId"] || payload[:sessionId],
        payload["entries"] || payload[:entries] || []
      )
    end)
  end

  defp install_peer_mailboxes(entries) when is_list(entries) do
    Enum.each(entries, fn entry ->
      payload = normalize_map(entry)

      Store.put(
        :mesh_peer_mailboxes,
        payload["sessionId"] || payload[:sessionId],
        payload["messages"] || payload[:messages] || []
      )
    end)
  end

  defp install_handoffs(entries) when is_list(entries) do
    Enum.each(entries, fn payload ->
      payload = normalize_map(payload)
      Store.put(:mesh_handoff_ops, payload["handoff_id"] || payload[:handoff_id], payload)
    end)
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
end
