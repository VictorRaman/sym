defmodule LemonControlPlane.Methods.MeshAgentMailboxAck do
  @moduledoc """
  Handler for `mesh.agent.mailbox.ack`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.agent.mailbox.ack"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    mesh_session_id = get_param(params, "meshSessionId")
    agent_id = get_param(params, "agentId")
    message_id = get_param(params, "messageId")
    expected_claimed_by = get_param(params, "expectedClaimedBy")

    cond do
      not (is_binary(mesh_session_id) and String.trim(mesh_session_id) != "") ->
        {:error, Errors.invalid_request("meshSessionId is required")}

      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, Errors.invalid_request("agentId is required")}

      not (is_binary(message_id) and String.trim(message_id) != "") ->
        {:error, Errors.invalid_request("messageId is required")}

      true ->
        case LemonMesh.ack_peer_message(
               mesh_session_id,
               message_id,
               acknowledged_by: agent_id,
               expected_to_agent: agent_id,
               expected_claimed_by: expected_claimed_by
             ) do
          {:ok, message} ->
            {:ok,
             %{
               "meshSessionId" => mesh_session_id,
               "agentId" => agent_id,
               "message" => format_message(message)
             }}

          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}

          {:error, :message_not_found} ->
            {:error, Errors.not_found("Mesh mailbox message not found")}
        end
    end
  end

  defp format_message(message) do
    %{
      "messageId" => message.message_id,
      "fromAgent" => message.from_agent,
      "toAgent" => message.to_agent,
      "channel" => message.channel,
      "vectorClock" => message.vector_clock,
      "payloadKind" => message.payload_kind,
      "payloadRef" => message.payload_ref,
      "payload" => message.payload,
      "dedupeKey" => message.dedupe_key,
      "insertedAtMs" => message.inserted_at_ms,
      "claimedAtMs" => message.claimed_at_ms,
      "claimExpiresAtMs" => message.claim_expires_at_ms,
      "claimedBy" => message.claimed_by,
      "acknowledgedAtMs" => message.acknowledged_at_ms,
      "acknowledgedBy" => message.acknowledged_by,
      "metadata" => message.metadata
    }
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
end
