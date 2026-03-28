defmodule LemonControlPlane.Methods.MeshSessionStart do
  @moduledoc """
  Handler for `mesh.session.start`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.session.start"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    goal = get_param(params, "goal") || get_param(params, "prompt")

    if not (is_binary(goal) and String.trim(goal) != "") do
      {:error, Errors.invalid_request("goal is required")}
    else
      attrs = %{
        goal: goal,
        roles: get_param(params, "roles") || [],
        peer_graph: get_param(params, "peerGraph") || %{},
        shared_files: get_param(params, "sharedFiles") || [],
        memory_scopes: get_param(params, "memoryScopes") || [],
        delivery_semantics: get_param(params, "deliverySemantics"),
        metadata: get_param(params, "metadata") || %{}
      }

      case LemonMesh.start_session(attrs) do
        {:ok, pid} when is_pid(pid) ->
          session_id = LemonMesh.session_id(pid)

          case LemonMesh.get_session(session_id) do
            {:ok, snapshot} ->
              {:ok, format_snapshot(snapshot)}

            {:error, :not_found} ->
              {:error, Errors.internal_error("Mesh session started but snapshot was unavailable")}
          end

        {:error, reason} ->
          {:error, Errors.internal_error("Failed to start mesh session", inspect(reason))}
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
