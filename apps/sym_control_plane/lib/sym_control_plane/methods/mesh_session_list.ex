defmodule LemonControlPlane.Methods.MeshSessionList do
  @moduledoc """
  Handler for `mesh.session.list`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "mesh.session.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    limit = get_param(params, "limit")
    status = get_param(params, "status")

    all_sessions =
      LemonMesh.list_sessions()
      |> maybe_filter_status(status)

    sessions =
      all_sessions
      |> maybe_take(limit)
      |> Enum.map(&format_snapshot/1)

    {:ok, %{"sessions" => sessions, "total" => length(all_sessions)}}
  end

  defp format_snapshot(snapshot) do
    %{
      "sessionId" => snapshot.session_id,
      "goal" => snapshot.goal,
      "status" => to_string(snapshot.status),
      "roles" => snapshot.roles,
      "sharedFiles" => snapshot.shared_files,
      "memoryScopes" => snapshot.memory_scopes,
      "blackboardCount" => snapshot.blackboard_size,
      "insertedAtMs" => snapshot.inserted_at_ms,
      "updatedAtMs" => snapshot.updated_at_ms
    }
  end

  defp get_param(params, key) when is_map(params) do
    underscored = Macro.underscore(key)
    Map.get(params, key) || Map.get(params, underscored)
  end

  defp maybe_filter_status(sessions, nil), do: sessions

  defp maybe_filter_status(sessions, status) do
    Enum.filter(sessions, fn session ->
      to_string(session.status) == to_string(status)
    end)
  end

  defp maybe_take(items, limit) when is_integer(limit) and limit >= 0, do: Enum.take(items, limit)
  defp maybe_take(items, _limit), do: items
end
