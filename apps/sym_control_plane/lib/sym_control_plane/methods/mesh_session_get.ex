defmodule LemonControlPlane.Methods.MeshSessionGet do
  @moduledoc """
  Handler for `mesh.session.get`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.session.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    session_id = get_param(params || %{}, "sessionId")

    cond do
      not is_binary(session_id) or String.trim(session_id) == "" ->
        {:error, Errors.invalid_request("sessionId is required")}

      true ->
        case LemonMesh.get_session(session_id) do
          {:ok, snapshot} ->
            {:ok, format_snapshot(snapshot)}

          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}
        end
    end
  end

  defp format_snapshot(snapshot) do
    %{
      "sessionId" => snapshot.session_id,
      "goal" => snapshot.goal,
      "status" => to_string(snapshot.status),
      "roles" => snapshot.roles,
      "peerGraph" => snapshot.peer_graph,
      "sharedFiles" => snapshot.shared_files,
      "memoryScopes" => snapshot.memory_scopes,
      "deliverySemantics" => snapshot.delivery_semantics,
      "blackboardCount" => snapshot.blackboard_size,
      "insertedAtMs" => snapshot.inserted_at_ms,
      "updatedAtMs" => snapshot.updated_at_ms,
      "metadata" => snapshot.metadata
    }
  end

  defp get_param(params, key) when is_map(params) do
    underscored = Macro.underscore(key)
    Map.get(params, key) || Map.get(params, underscored)
  end
end
