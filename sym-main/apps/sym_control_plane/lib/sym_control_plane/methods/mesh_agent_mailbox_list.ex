defmodule LemonControlPlane.Methods.MeshAgentMailboxList do
  @moduledoc """
  Handler for `mesh.agent.mailbox.list`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mesh.agent.mailbox.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    mesh_session_id = get_param(params, "meshSessionId")
    agent_id = get_param(params, "agentId")
    limit = get_param(params, "limit")
    include_claimed = get_param(params, "includeClaimed")

    cond do
      not (is_binary(mesh_session_id) and String.trim(mesh_session_id) != "") ->
        {:error, Errors.invalid_request("meshSessionId is required")}

      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, Errors.invalid_request("agentId is required")}

      true ->
        include_claimed? = truthy?(include_claimed)

        opts =
          [
            to_agent: agent_id,
            limit: if(include_claimed?, do: nil, else: limit),
            pending_only: not include_claimed?
          ]

        case LemonMesh.list_peer_messages(mesh_session_id, opts) do
          {:ok, messages} ->
            messages =
              messages
              |> filter_messages(include_claimed?)
              |> maybe_take(limit)

            {:ok,
             %{
               "meshSessionId" => mesh_session_id,
               "agentId" => agent_id,
               "messages" => Enum.map(messages, &format_message/1),
               "total" => length(messages)
             }}

          {:error, :not_found} ->
            {:error, Errors.not_found("Mesh session not found")}
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp filter_messages(messages, true) do
    Enum.filter(messages, &is_nil(&1.acknowledged_at_ms))
  end

  defp filter_messages(messages, _include_claimed?), do: messages

  defp maybe_take(messages, limit) when is_integer(limit) and limit >= 0, do: Enum.take(messages, limit)
  defp maybe_take(messages, _limit), do: messages

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
