defmodule LemonMesh.WorktreeLeaseTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{OpLog, Store}
  alias LemonMesh.Replication.{Projector, Watermark}

  setup do
    Application.ensure_all_started(:lemon_mesh)

    OpLog.reset()
    Watermark.reset()

    for {key, _value} <- CoreStore.list(:mesh_worktree_leases) do
      CoreStore.delete(:mesh_worktree_leases, key)
    end

    :ok
  end

  test "higher lease_epoch wins for the same repo slice" do
    assert {:ok, _lease} =
             Store.record_worktree_lease("repo:alpha", "lease_acquired", %{
               agent_id: "agent-a",
               worktree_path: "/tmp/worktree-a",
               lease_epoch: 1,
               origin_node_id: "node-b",
               expires_at_ms: 200
             })

    assert {:ok, _lease} =
             Store.record_worktree_lease("repo:alpha", "lease_taken_over", %{
               agent_id: "agent-b",
               worktree_path: "/tmp/worktree-b",
               lease_epoch: 2,
               origin_node_id: "node-a",
               expires_at_ms: 300
             })

    assert {:ok, lease} = Store.get_worktree_lease("repo:alpha")
    assert lease.agent_id == "agent-b"
    assert lease.worktree_path == "/tmp/worktree-b"
    assert lease.lease_epoch == 2
    assert lease.origin_node_id == "node-a"
  end

  test "same lease_epoch uses origin_node_id as deterministic tiebreak" do
    assert {:ok, _lease} =
             Projector.project(
               LemonMesh.Op.new(%{
                 op_id: "repo:beta:lease_acquired:1",
                 origin_node_id: "node-b",
                 entity_type: "worktree_lease",
                 entity_id: "repo:beta",
                 op_type: "lease_acquired",
                 causal_clock: %{"node-b" => 1},
                 payload: %{
                   agent_id: "agent-b",
                   worktree_path: "/tmp/worktree-b",
                   lease_epoch: 5,
                   expires_at_ms: 500
                 }
               })
             )

    assert {:ok, _lease} =
             Projector.project(
               LemonMesh.Op.new(%{
                 op_id: "repo:beta:lease_taken_over:1",
                 origin_node_id: "node-a",
                 entity_type: "worktree_lease",
                 entity_id: "repo:beta",
                 op_type: "lease_taken_over",
                 causal_clock: %{"node-a" => 1},
                 payload: %{
                   agent_id: "agent-a",
                   worktree_path: "/tmp/worktree-a",
                   lease_epoch: 5,
                   expires_at_ms: 500
                 }
               })
             )

    assert {:ok, lease} = Store.get_worktree_lease("repo:beta")
    assert lease.agent_id == "agent-a"
    assert lease.origin_node_id == "node-a"
  end
end
