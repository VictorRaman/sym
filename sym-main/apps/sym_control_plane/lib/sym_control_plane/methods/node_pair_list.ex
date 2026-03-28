defmodule LemonControlPlane.Methods.NodePairList do
  @moduledoc """
  Handler for the node.pair.list control plane method.

  Lists pending pairing requests.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore

  @impl true
  def name, do: "node.pair.list"

  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(_params, _ctx) do
    now = System.system_time(:millisecond)

    # Get all pairing requests
    requests =
      NodeStore.list_pairings()
      |> Enum.map(fn {_id, request} -> request end)
      |> Enum.filter(fn request ->
        # Only pending and not expired
        status = get_field(request, :status)
        expires_at_ms = get_field(request, :expires_at_ms)

        status in [:pending, "pending"] and
          (is_nil(expires_at_ms) or expires_at_ms > now)
      end)
      |> Enum.map(&format_request/1)

    {:ok, %{"requests" => requests}}
  end

  defp format_request(request) do
    pairing_id = get_field(request, :id)

    %{
      "pairingId" => pairing_id,
      "code" => NodeStore.get_pairing_display_code(pairing_id),
      "nodeType" => get_field(request, :node_type),
      "nodeName" => get_field(request, :node_name),
      "capabilities" => get_field(request, :capabilities) || %{},
      "expiresAtMs" => get_field(request, :expires_at_ms),
      "createdAtMs" => get_field(request, :created_at_ms)
    }
  end

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
