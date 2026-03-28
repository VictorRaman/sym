defmodule CodingAgent.Tools.MeshMailbox do
  @moduledoc """
  Tool for consuming Lemon Mesh peer mailbox messages from a coding agent.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @valid_actions ["list", "ack"]

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    current_agent_id = Keyword.get(opts, :agent_id, "default")

    %AgentTool{
      name: "mesh_mailbox",
      description: "List or acknowledge pending Lemon Mesh mailbox messages.",
      label: "Mesh Mailbox",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" => "Mailbox action to run: 'list' or 'ack'."
          },
          "mesh_session_id" => %{
            "type" => "string",
            "description" => "Lemon Mesh session id that owns the mailbox."
          },
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Optional agent id override. Defaults to the current agent identity."
          },
          "message_id" => %{
            "type" => "string",
            "description" => "Mailbox message id to acknowledge when action is 'ack'."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of pending messages to return when action is 'list'."
          }
        },
        "required" => ["action", "mesh_session_id"]
      },
      execute: &execute(&1, &2, &3, &4, current_agent_id)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, (AgentToolResult.t() -> :ok) | nil, String.t()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, current_agent_id) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, action} <- get_action(params),
           {:ok, mesh_session_id} <- get_mesh_session_id(params),
           {:ok, agent_id} <- resolve_agent_id(params, current_agent_id) do
        case action do
          "list" -> execute_list(mesh_session_id, agent_id, params)
          "ack" -> execute_ack(mesh_session_id, agent_id, params)
        end
      end
    end
  end

  defp execute_list(mesh_session_id, agent_id, params) do
    opts =
      [to_agent: agent_id]
      |> maybe_put_limit(Map.get(params, "limit"))

    case LemonMesh.list_peer_messages(mesh_session_id, opts) do
      {:ok, messages} ->
        text =
          case messages do
            [] ->
              "No pending mesh mailbox messages for #{agent_id}."

            _ ->
              messages
              |> Enum.map(fn message ->
                "- #{message.message_id} from #{message.from_agent || "unknown"} " <>
                  "[#{message.payload_kind || "message"}]"
              end)
              |> Enum.join("\n")
          end

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: %{
            status: "ok",
            action: "list",
            mesh_session_id: mesh_session_id,
            agent_id: agent_id,
            total: length(messages),
            messages: messages
          }
        }

      {:error, :not_found} ->
        {:error, "mesh session not found"}
    end
  end

  defp execute_ack(mesh_session_id, agent_id, params) do
    with {:ok, message_id} <- get_message_id(params) do
      case LemonMesh.ack_peer_message(
             mesh_session_id,
             message_id,
             acknowledged_by: agent_id,
             expected_to_agent: agent_id
           ) do
        {:ok, message} ->
          %AgentToolResult{
            content: [
              %TextContent{
                text: "Acknowledged mesh mailbox message #{message.message_id} for #{agent_id}."
              }
            ],
            details: %{
              status: "ok",
              action: "ack",
              mesh_session_id: mesh_session_id,
              agent_id: agent_id,
              message: message
            }
          }

        {:error, :not_found} ->
          {:error, "mesh session not found"}

        {:error, :message_not_found} ->
          {:error, "message not found for agent"}
      end
    end
  end

  defp get_action(%{"action" => action}) when action in @valid_actions, do: {:ok, action}
  defp get_action(%{"action" => _}), do: {:error, "action must be one of: list, ack"}
  defp get_action(_), do: {:error, "action is required and must be one of: list, ack"}

  defp get_mesh_session_id(%{"mesh_session_id" => mesh_session_id}) when is_binary(mesh_session_id) do
    mesh_session_id = String.trim(mesh_session_id)

    if mesh_session_id == "" do
      {:error, "mesh_session_id must be a non-empty string"}
    else
      {:ok, mesh_session_id}
    end
  end

  defp get_mesh_session_id(%{"mesh_session_id" => _}),
    do: {:error, "mesh_session_id must be a string"}

  defp get_mesh_session_id(_), do: {:error, "mesh_session_id is required"}

  defp resolve_agent_id(%{"agent_id" => agent_id}, _current_agent_id) when is_binary(agent_id) do
    agent_id = String.trim(agent_id)

    if agent_id == "" do
      {:error, "agent_id must be a non-empty string"}
    else
      {:ok, agent_id}
    end
  end

  defp resolve_agent_id(%{"agent_id" => _}, _current_agent_id),
    do: {:error, "agent_id must be a string"}

  defp resolve_agent_id(_params, current_agent_id) when is_binary(current_agent_id) do
    agent_id = String.trim(current_agent_id)

    if agent_id == "" do
      {:error, "agent_id unavailable"}
    else
      {:ok, agent_id}
    end
  end

  defp resolve_agent_id(_params, _current_agent_id), do: {:error, "agent_id unavailable"}

  defp get_message_id(%{"message_id" => message_id}) when is_binary(message_id) do
    message_id = String.trim(message_id)

    if message_id == "" do
      {:error, "message_id must be a non-empty string"}
    else
      {:ok, message_id}
    end
  end

  defp get_message_id(%{"message_id" => _}), do: {:error, "message_id must be a string"}
  defp get_message_id(_), do: {:error, "message_id is required for action=ack"}

  defp maybe_put_limit(opts, limit) when is_integer(limit) and limit >= 0,
    do: Keyword.put(opts, :limit, limit)

  defp maybe_put_limit(opts, _limit), do: opts
end
