defmodule LemonControlPlane.Methods.MeshBlackboardAppend do
  @moduledoc """
  Handler for `mesh.blackboard.append`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.blackboard.append"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_id = get_param(params, "sessionId")
    kind = get_param(params, "kind")
    body = get_param(params, "body")

    cond do
      not is_binary(session_id) or String.trim(session_id) == "" ->
        {:error, Errors.invalid_request("sessionId is required")}

      not is_binary(kind) or String.trim(kind) == "" ->
        {:error, Errors.invalid_request("kind is required")}

      is_nil(body) ->
        {:error, Errors.invalid_request("body is required")}

      true ->
        attrs = %{
          kind: kind,
          body: body,
          author: get_param(params, "author"),
          scope: get_param(params, "scope"),
          clock: get_param(params, "clock"),
          supersedes: get_param(params, "supersedes"),
          artifact_refs: get_param(params, "artifactRefs") || []
        }

        case LemonMesh.append_blackboard_entry(session_id, attrs) do
          {:ok, entry} ->
            {:ok, format_entry(session_id, entry)}

          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}

          {:error, {:invalid_blackboard_entry, :kind_required}} ->
            {:error, Errors.invalid_request("kind is required")}

          {:error, {:invalid_blackboard_entry, :body_required}} ->
            {:error, Errors.invalid_request("body is required")}

          {:error, reason} ->
            {:error, Errors.internal_error("Failed to append blackboard entry", inspect(reason))}
        end
    end
  end

  defp format_entry(session_id, entry) do
    %{
      "sessionId" => session_id,
      "entry" => %{
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
    }
  end

  defp get_param(params, key) when is_map(params) do
    underscored = Macro.underscore(key)
    Map.get(params, key) || Map.get(params, underscored)
  end
end
