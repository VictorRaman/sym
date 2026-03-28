defmodule LemonMesh.OpLogTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{HandoffStore, Op, OpLog}
  alias LemonMesh.Replication.{Projector, Watermark}

  setup do
    Application.ensure_all_started(:lemon_mesh)
    HandoffStore.reset()
    OpLog.reset()
    Watermark.reset()
    :ok
  end

  test "append stores a normalized op and dedupes by op_id" do
    assert {:ok, op} =
             OpLog.append(%{
               op_id: "op_handoff_created_1",
               entity_type: "handoff",
               entity_id: "handoff_1",
               op_type: "created",
               payload: %{"prompt" => "review this"}
             })

    assert op.op_id == "op_handoff_created_1"
    assert op.entity_type == "handoff"
    assert op.entity_id == "handoff_1"
    assert op.op_type == "created"
    assert is_binary(op.origin_node_id)
    assert op.causal_clock[op.origin_node_id] == 1

    assert {:ok, duplicate} =
             OpLog.append(%{
               op_id: "op_handoff_created_1",
               entity_type: "handoff",
               entity_id: "handoff_1",
               op_type: "created",
               payload: %{"prompt" => "changed payload should be ignored"}
             })

    assert duplicate == op

    assert [stored] = OpLog.list(entity_type: "handoff", entity_id: "handoff_1")
    assert stored == op
  end

  test "append advances the causal clock monotonically for the same entity on the same node" do
    assert {:ok, first} =
             OpLog.append(%{
               op_id: "op_handoff_state_1",
               entity_type: "handoff",
               entity_id: "handoff_clock_1",
               op_type: "created",
               payload: %{}
             })

    assert {:ok, second} =
             OpLog.append(%{
               op_id: "op_handoff_state_2",
               entity_type: "handoff",
               entity_id: "handoff_clock_1",
               op_type: "delivery_accepted",
               payload: %{}
             })

    assert first.origin_node_id == second.origin_node_id
    assert first.causal_clock[first.origin_node_id] == 1
    assert second.causal_clock[second.origin_node_id] == 2
  end

  test "handoff lifecycle emits op-log entries for durable state transitions" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_oplog_1",
               mesh_session_id: "mesh_oplog_1",
               agent_id: "reviewer",
               prompt: "Track me in the op log",
               queue_mode: "followup"
             })

    assert {:ok, handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_oplog_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, _handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_oplog_1", 20)

    ops = OpLog.list(entity_type: "handoff", entity_id: handoff.handoff_id)

    assert Enum.map(ops, & &1.op_type) == [
             "created",
             "delivery_accepted",
             "mailbox_persisted"
           ]

    assert Enum.all?(ops, fn op ->
             op.entity_type == "handoff" and op.entity_id == handoff.handoff_id
           end)
  end

  test "projector can rebuild a handoff read model from authoritative ops" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_projector_1",
               mesh_session_id: "mesh_projector_1",
               agent_id: "reviewer",
               prompt: "Rebuild me from the op log",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_projector_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, _handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_projector_1", 20)

    assert :ok = CoreStore.delete(:mesh_handoff_ops, handoff.handoff_id)
    assert {:error, :not_found} = HandoffStore.get(handoff.handoff_id)

    assert {:ok, rebuilt} = Projector.rebuild_entity("handoff", handoff.handoff_id)
    assert rebuilt.handoff_id == handoff.handoff_id
    assert rebuilt.delivery_state == :mailbox_persisted
    assert rebuilt.message_id == "msg_projector_1"

    assert {:ok, stored} = HandoffStore.get(handoff.handoff_id)
    assert stored == rebuilt
  end

  test "authoritative handoff writes advance the local watermark" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_watermark_1",
               mesh_session_id: "mesh_watermark_1",
               agent_id: "reviewer",
               prompt: "Advance the watermark",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_watermark_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, _handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_watermark_1", 20)

    [last_op | _rest] =
      handoff.handoff_id
      |> then(&OpLog.list(entity_type: "handoff", entity_id: &1))
      |> Enum.reverse()

    local_watermark = Watermark.local()

    assert local_watermark[last_op.origin_node_id] == 3
  end

  test "rebuild_all replays the handoff read model idempotently" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_rebuild_all_1",
               mesh_session_id: "mesh_rebuild_all_1",
               agent_id: "reviewer",
               prompt: "Replay me repeatedly",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_rebuild_all_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert :ok = CoreStore.delete(:mesh_handoff_ops, handoff.handoff_id)

    assert :ok = Projector.rebuild_all()
    assert {:ok, first} = HandoffStore.get(handoff.handoff_id)

    assert :ok = Projector.rebuild_all()
    assert {:ok, second} = HandoffStore.get(handoff.handoff_id)

    assert first == second
    assert first.delivery_state == :delivery_accepted
  end

  test "projector preserves durable handoff fields when a later op payload is partial" do
    assert {:ok, _handoff} =
             Projector.project(
               Op.new(%{
                 op_id: "handoff_partial_1:mailbox_persisted",
                 entity_type: "handoff",
                 entity_id: "handoff_partial_1",
                 op_type: "mailbox_persisted",
                 causal_clock: %{"node-a" => 1},
                 payload: %{
                   handoff_id: "handoff_partial_1",
                   mesh_session_id: "mesh_partial_1",
                   agent_id: "reviewer",
                   prompt: "Keep the durable fields",
                   queue_mode: "followup",
                   delivery_state: :mailbox_persisted,
                   message_id: "msg_partial_1",
                   mailbox_persisted_at_ms: 20
                 }
               })
             )

    assert {:ok, _handoff} =
             Projector.project(
               Op.new(%{
                 op_id: "handoff_partial_1:runtime_applied",
                 entity_type: "handoff",
                 entity_id: "handoff_partial_1",
                 op_type: "runtime_applied",
                 causal_clock: %{"node-a" => 2},
                 payload: %{
                   handoff_id: "handoff_partial_1",
                   mesh_session_id: "mesh_partial_1",
                   agent_id: "reviewer",
                   prompt: "Keep the durable fields",
                   queue_mode: "followup",
                   delivery_state: :runtime_applied,
                   runtime_applied_at_ms: 30,
                   completed_at_ms: 30
                 }
               })
             )

    assert {:ok, stored} = HandoffStore.get("handoff_partial_1")
    assert stored.message_id == "msg_partial_1"
    assert stored.mailbox_persisted_at_ms == 20
    assert stored.runtime_applied_at_ms == 30
    assert stored.completed_at_ms == 30
    assert stored.delivery_state == :runtime_applied
  end
end
