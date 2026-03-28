defmodule LemonControlPlane.Methods.MeshReplicationStatusTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.MeshReplicationStatus

  defmodule ManagerStub do
    def status do
      %{
        trusted_peers: ["peer-a@host"],
        local_watermark: %{"local@host" => 3},
        inbound_watermarks: %{"peer-a@host" => %{"peer-a@host" => 2}},
        outbound_watermarks: %{"peer-a@host" => %{"local@host" => 3}},
        peers: [
          %{
            peer_id: "peer-a@host",
            status: :healthy,
            bootstrapped?: true,
            bootstrap_state: :bootstrapped,
            bootstrap_target_watermark: %{"peer-a@host" => 3},
            backfill_complete: true,
            backfill_lag: 0,
            last_success_at_ms: 123,
            last_error: nil
          }
        ]
      }
    end
  end

  setup do
    previous = Application.get_env(:lemon_control_plane, :mesh_replication_status_manager)

    Application.put_env(
      :lemon_control_plane,
      :mesh_replication_status_manager,
      ManagerStub
    )

    on_exit(fn ->
      case previous do
        nil ->
          Application.delete_env(:lemon_control_plane, :mesh_replication_status_manager)

        value ->
          Application.put_env(:lemon_control_plane, :mesh_replication_status_manager, value)
      end
    end)

    :ok
  end

  test "returns replication status with peer and watermark visibility" do
    assert {:ok, payload} = MeshReplicationStatus.handle(%{}, %{})
    assert payload["trustedPeers"] == ["peer-a@host"]
    assert payload["localWatermark"] == %{"local@host" => 3}
    assert payload["inboundWatermarks"]["peer-a@host"] == %{"peer-a@host" => 2}
    assert payload["outboundWatermarks"]["peer-a@host"] == %{"local@host" => 3}
    assert hd(payload["peers"])["peerId"] == "peer-a@host"
    assert hd(payload["peers"])["bootstrapped"] == true
    assert hd(payload["peers"])["bootstrapState"] == "bootstrapped"
    assert hd(payload["peers"])["bootstrapTargetWatermark"] == %{"peer-a@host" => 3}
    assert hd(payload["peers"])["backfillComplete"] == true
    assert hd(payload["peers"])["backfillLag"] == 0
    assert hd(payload["peers"])["status"] == "healthy"
  end
end
