defmodule LemonMesh.Replication.BeamRpcTest do
  use ExUnit.Case, async: false

  alias LemonMesh.{HandoffStore, OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.{BeamRpc, Watermark}

  setup do
    Application.ensure_all_started(:lemon_mesh)

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)

    Store.reset()
    HandoffStore.reset()
    OpLog.reset()
    Watermark.reset()
    :ok
  end

  test "serves snapshots and pull ops while advancing outbound watermark" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_beam_rpc_1",
               mesh_session_id: "mesh_beam_rpc_1",
               agent_id: "reviewer",
               prompt: "Serve me over Beam RPC",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_beam_rpc_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, snapshot} = BeamRpc.get_snapshot_for("peer-b@host", "mesh_state")
    assert snapshot["scope"] == "mesh_state"
    assert is_map(snapshot["watermark"])
    assert length(snapshot["entities"]["handoffs"]) >= 1

    assert {:ok, ops} = BeamRpc.pull_ops_for("peer-b@host", %{}, 10)
    assert Enum.any?(ops, &(&1.entity_id == "handoff_beam_rpc_1"))

    assert Watermark.outbound("peer-b@host")["nonode:LAPTOP-DRMVN5PI"] ||
             Watermark.outbound("peer-b@host") != %{}
  end
end
