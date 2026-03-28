defmodule LemonControlPlane.Methods.MeshReplicationStatus do
  @moduledoc """
  Handler for `mesh.replication.status`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "mesh.replication.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    manager =
      Application.get_env(
        :lemon_control_plane,
        :mesh_replication_status_manager,
        LemonMesh.Replication.Manager
      )

    status = manager.status()

    {:ok,
     %{
       "trustedPeers" => status.trusted_peers,
       "localWatermark" => status.local_watermark,
       "inboundWatermarks" => status.inbound_watermarks,
       "outboundWatermarks" => status.outbound_watermarks,
       "peers" => Enum.map(status.peers, &format_peer_status/1)
     }}
  end

  defp format_peer_status(status) do
    %{
      "peerId" => status.peer_id,
      "status" => to_string(status.status),
      "bootstrapped" => status.bootstrapped?,
      "bootstrapState" => format_bootstrap_state(Map.get(status, :bootstrap_state)),
      "bootstrapTargetWatermark" => Map.get(status, :bootstrap_target_watermark),
      "backfillComplete" => Map.get(status, :backfill_complete),
      "backfillLag" => Map.get(status, :backfill_lag),
      "lastSuccessAtMs" => status.last_success_at_ms,
      "lastError" => format_error(status.last_error)
    }
  end

  defp format_bootstrap_state(nil), do: nil
  defp format_bootstrap_state(value) when is_atom(value), do: Atom.to_string(value)
  defp format_bootstrap_state(value) when is_binary(value), do: value
  defp format_bootstrap_state(value), do: inspect(value)

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
