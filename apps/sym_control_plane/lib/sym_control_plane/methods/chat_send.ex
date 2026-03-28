defmodule LemonControlPlane.Methods.ChatSend do
  @moduledoc """
  Handler for the chat.send method.

  Sends a message to a session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.QueueMode

  @allowed_queue_modes [:collect, :followup, :steer, :interrupt]

  @impl true
  def name, do: "chat.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = get_param(params, "sessionKey")
    prompt = get_param(params, "prompt") || get_param(params, "message")
    agent_id = get_param(params, "agentId")

    queue_mode =
      QueueMode.parse(get_param(params, "queueMode"),
        default: :collect,
        allowed: @allowed_queue_modes
      )

    cond do
      is_nil(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      is_nil(prompt) ->
        {:error, {:invalid_request, "prompt is required", nil}}

      true ->
        submit_params = %{
          origin: :control_plane,
          session_key: session_key,
          agent_id: agent_id,
          prompt: prompt,
          queue_mode: queue_mode,
          meta: %{
            control_plane: true
          }
        }

        case router_module().submit(submit_params) do
          {:ok, run_id} ->
            {:ok, %{
              "runId" => run_id,
              "sessionKey" => session_key
            }}

          {:error, reason} ->
            {:error, {:internal_error, inspect(reason), nil}}
        end
    end
  end

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil

  defp router_module do
    Application.get_env(:lemon_control_plane, :chat_send_router, LemonRouter)
  end
end
