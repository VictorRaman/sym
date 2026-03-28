defmodule LemonControlPlane.Methods.MeshAgentMessage do
  @moduledoc """
  Handler for `mesh.agent.message`.

  Sends a directed message into an agent inbox while mirroring the handoff into
  the owning Lemon Mesh session blackboard.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.QueueMode
  alias LemonControlPlane.Protocol.Errors
  alias LemonMesh.HandoffDispatcher

  @impl true
  def name, do: "mesh.agent.message"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    mesh_session_id = get_param(params, "meshSessionId")
    agent_id = get_param(params, "agentId")
    prompt = get_param(params, "prompt")

    cond do
      not (is_binary(mesh_session_id) and String.trim(mesh_session_id) != "") ->
        {:error, Errors.invalid_request("meshSessionId is required")}

      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, Errors.invalid_request("agentId is required")}

      not (is_binary(prompt) and String.trim(prompt) != "") ->
        {:error, Errors.invalid_request("prompt is required")}

      true ->
        with {:ok, result} <-
               HandoffDispatcher.dispatch(%{
                 mesh_session_id: mesh_session_id,
                 agent_id: agent_id,
                 prompt: prompt,
                 queue_mode: QueueMode.label(get_param(params, "queueMode"), default: :followup),
                 meta: normalize_map(get_param(params, "meta")),
                 send_opts: build_send_opts(mesh_session_id, params),
                 send_fn: fn routed_agent_id, routed_prompt, send_opts ->
                   router_module().send_to_agent(routed_agent_id, routed_prompt, send_opts)
                 end
               }) do
          {:ok,
           %{
             "meshSessionId" => mesh_session_id,
             "handoffId" => result.handoff_id,
             "runId" => result.run_id,
             "sessionKey" => result.session_key,
             "selector" => selector_label(result.selector),
             "fanoutCount" => result.fanout_count || 0,
             "messageId" => result.message_id,
             "handoffEntryId" => result.handoff_entry_id,
             "deliveryAccepted" => result.delivery_accepted,
             "mailboxPersisted" => result.mailbox_persisted,
             "blackboardPersisted" => result.blackboard_persisted
           }}
        else
          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}

          {:error, {:send_failed, reason}} ->
            {:error, Errors.internal_error("Failed to send mesh agent message", inspect(reason))}

          {:error, reason} ->
            {:error, Errors.internal_error("Failed to record mesh handoff", inspect(reason))}
        end
    end
  end

  defp build_send_opts(mesh_session_id, params) do
    meta =
      normalize_map(get_param(params, "meta"))
      |> Map.put("mesh_session_id", mesh_session_id)

    [
      session: parse_session_selector(params),
      queue_mode: QueueMode.parse(get_param(params, "queueMode"), default: :followup),
      engine_id: get_param(params, "engineId"),
      model: get_param(params, "model"),
      cwd: get_param(params, "cwd"),
      tool_policy: get_param(params, "toolPolicy"),
      meta: meta,
      source: "control_plane_mesh"
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_session_selector(params) do
    cond do
      get_param(params, "sessionKey") in [:latest, :new] ->
        get_param(params, "sessionKey")

      is_binary(get_param(params, "sessionKey")) ->
        get_param(params, "sessionKey")

      get_param(params, "session") in [:latest, :new] ->
        get_param(params, "session")

      is_binary(get_param(params, "session")) ->
        get_param(params, "session")

      true ->
        :latest
    end
  end

  defp selector_label(selector) when is_atom(selector), do: Atom.to_string(selector)
  defp selector_label(selector) when is_binary(selector), do: "explicit"
  defp selector_label(_), do: "unknown"

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

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
    Application.get_env(:lemon_control_plane, :mesh_agent_message_router, LemonRouter)
  end
end
