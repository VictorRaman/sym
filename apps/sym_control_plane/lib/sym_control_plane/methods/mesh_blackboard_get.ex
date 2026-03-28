defmodule LemonControlPlane.Methods.MeshBlackboardGet do
  @moduledoc """
  Handler for `mesh.blackboard.get`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.blackboard.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_id = get_param(params, "sessionId")
    kind = get_param(params, "kind")
    limit = get_param(params, "limit")

    cond do
      not is_binary(session_id) or String.trim(session_id) == "" ->
        {:error, Errors.invalid_request("sessionId is required")}

      true ->
        case LemonMesh.list_blackboard_entries(session_id) do
          {:ok, entries} ->
            filtered =
              entries
              |> maybe_filter_kind(kind)
              |> maybe_take(limit)

            {:ok,
             %{
               "sessionId" => session_id,
               "entries" => Enum.map(filtered, &format_entry/1),
               "total" => length(filtered)
             }}

          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}
        end
    end
  end

  defp format_entry(entry) do
    %{
      "entryId" => entry.entry_id,
      "kind" => entry.kind,
      "author" => entry.author,
      "scope" => entry.scope,
      "body" => entry.body,
      "clock" => entry.clock,
      "supersedes" => entry.supersedes,
      "artifactRefs" => entry.artifact_refs,
      "insertedAtMs" => entry.inserted_at_ms
    }
  end

  defp get_param(params, key) when is_map(params) do
    underscored = Macro.underscore(key)
    Map.get(params, key) || Map.get(params, underscored)
  end

  defp maybe_filter_kind(entries, nil), do: entries

  defp maybe_filter_kind(entries, kind) do
    Enum.filter(entries, fn entry ->
      to_string(entry.kind) == to_string(kind)
    end)
  end

  defp maybe_take(items, limit) when is_integer(limit) and limit >= 0, do: Enum.take(items, limit)
  defp maybe_take(items, _limit), do: items
end
