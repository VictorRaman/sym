defmodule LemonMesh.Replication.PeerWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{HandoffStore, Op, OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.{PeerWorker, Snapshot, Watermark}

  defmodule TransportStub do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            snapshot_calls: 0,
            pull_calls: 0
          }
        end,
        name: __MODULE__
      )
    end

    def get_snapshot(_peer_id, "mesh_state", _opts) do
      Agent.update(__MODULE__, &Map.update!(&1, :snapshot_calls, fn value -> value + 1 end))

      {:ok,
       %{
         "scope" => "mesh_state",
         "generatedAtMs" => 1,
         "watermark" => %{"peer-a@host" => 4},
         "entities" => %{
           "sessions" => [
             %{
               session_id: "mesh_bootstrap_1",
               goal: "Bootstrapped from peer snapshot",
               roles: ["reviewer"],
               peer_graph: %{},
               shared_files: [],
               memory_scopes: [],
               delivery_semantics: "at_least_once",
               metadata: %{},
               status: :stopped,
               blackboard_size: 0,
               inserted_at_ms: 1,
               updated_at_ms: 1
             }
           ],
           "blackboards" => [],
           "peerMailboxes" => [],
           "handoffs" => []
         }
       }}
    end

    def pull_ops(_peer_id, _after_watermark, _limit, _opts) do
      pull_calls =
        Agent.get_and_update(__MODULE__, fn state ->
          next = state.pull_calls + 1
          {next, %{state | pull_calls: next}}
        end)

      ops =
        if pull_calls == 1 do
          [
            Op.new(%{
              op_id: "handoff_peer_worker_1:created",
              origin_node_id: "peer-a@host",
              entity_type: "handoff",
              entity_id: "handoff_peer_worker_1",
              op_type: "created",
              causal_clock: %{"peer-a@host" => 2},
              payload: %{
                handoff_id: "handoff_peer_worker_1",
                mesh_session_id: "mesh_bootstrap_1",
                agent_id: "reviewer",
                prompt: "Pulled from peer ops",
                queue_mode: "followup",
                delivery_state: :created
              }
            }),
            Op.new(%{
              op_id: "msg_peer_worker_1:message_created",
              origin_node_id: "peer-a@host",
              entity_type: "peer_mailbox",
              entity_id: "msg_peer_worker_1",
              op_type: "message_created",
              causal_clock: %{"peer-a@host" => 3},
              payload: %{
                message_id: "msg_peer_worker_1",
                session_id: "mesh_bootstrap_1",
                from_agent: "planner",
                to_agent: "reviewer",
                channel: "mesh",
                origin_node_id: "peer-a@host",
                vector_clock: %{"peer-a@host" => 2},
                delivery_epoch: 0,
                payload_kind: "prompt",
                payload_ref: nil,
                payload: %{"prompt" => "Pulled mailbox message"},
                dedupe_key: "msg_peer_worker_1",
                inserted_at_ms: 2,
                claimed_at_ms: nil,
                claim_expires_at_ms: nil,
                claimed_by: nil,
                lease_epoch: 0,
                acknowledged_at_ms: nil,
                acknowledged_by: nil,
                metadata: %{"queue_mode" => "followup"}
              }
            })
          ]
        else
          [
            Op.new(%{
              op_id: "handoff_peer_worker_1:delivery_accepted",
              origin_node_id: "peer-a@host",
              entity_type: "handoff",
              entity_id: "handoff_peer_worker_1",
              op_type: "delivery_accepted",
              causal_clock: %{"peer-a@host" => 4},
              payload: %{
                handoff_id: "handoff_peer_worker_1",
                mesh_session_id: "mesh_bootstrap_1",
                agent_id: "reviewer",
                prompt: "Pulled from peer ops",
                queue_mode: "followup",
                delivery_state: :delivery_accepted,
                run_id: "run_peer_worker_1",
                session_key: "agent:reviewer:main",
                delivery_sent_at_ms: 4
              }
            })
          ]
        end

      {:ok, ops}
    end
  end

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

    for {key, _value} <- CoreStore.list(:coding_agent_runtime_mailbox_journal) do
      CoreStore.delete(:coding_agent_runtime_mailbox_journal, key)
    end

    start_supervised!(TransportStub)
    :ok
  end

  test "stays bootstrapping until inbound watermark covers the snapshot target watermark" do
    {:ok, worker} =
      start_supervised(
        {PeerWorker,
         name: :"peer_worker_#{System.unique_integer([:positive])}",
         peer_id: "peer-a@host",
         transport: TransportStub,
         poll_interval_ms: 25,
         batch_limit: 10,
         snapshot_scope: "mesh_state"}
      )

    wait_for(fn ->
      Watermark.inbound("peer-a@host")["peer-a@host"] == 3
    end)

    status = PeerWorker.status(worker)
    assert status.peer_id == "peer-a@host"
    assert status.bootstrapped? == false
    assert status.bootstrap_state == :bootstrapping
    assert status.bootstrap_target_watermark == %{"peer-a@host" => 4}
    assert status.backfill_complete == false
    assert status.backfill_lag == 1
    assert status.last_error == nil
    assert is_integer(status.last_success_at_ms)

    assert {:ok, session} = LemonMesh.get_session("mesh_bootstrap_1")
    assert session.goal == "Bootstrapped from peer snapshot"

    assert {:ok, [message]} =
             LemonMesh.list_peer_messages("mesh_bootstrap_1",
               to_agent: "reviewer",
               pending_only: false
             )

    assert message.message_id == "msg_peer_worker_1"
    assert message.payload == %{"prompt" => "Pulled mailbox message"}
  end

  test "marks the peer bootstrapped after backfill reaches the target watermark" do
    {:ok, worker} =
      start_supervised(
        {PeerWorker,
         name: :"peer_worker_#{System.unique_integer([:positive])}",
         peer_id: "peer-a@host",
         transport: TransportStub,
         poll_interval_ms: 60_000,
         batch_limit: 10,
         snapshot_scope: "mesh_state"}
      )

    wait_for(fn ->
      Watermark.inbound("peer-a@host")["peer-a@host"] == 3
    end)

    send(worker, :sync_tick)

    wait_for(fn ->
      Watermark.inbound("peer-a@host")["peer-a@host"] == 4
    end)

    status = PeerWorker.status(worker)
    assert status.peer_id == "peer-a@host"
    assert status.bootstrapped? == true
    assert status.bootstrap_state == :bootstrapped
    assert status.bootstrap_target_watermark == %{"peer-a@host" => 4}
    assert status.backfill_complete == true
    assert status.backfill_lag == 0
    assert status.last_error == nil
    assert is_integer(status.last_success_at_ms)
  end

  test "fails closed when local state is non-empty and no inbound watermark exists" do
    capture_log(fn ->
      {:ok, _pid} = LemonMesh.start_session(goal: "Pre-existing local state")

      {:ok, worker} =
        start_supervised(
          {PeerWorker,
           name: :"peer_worker_#{System.unique_integer([:positive])}",
           peer_id: "peer-a@host",
           transport: TransportStub,
           poll_interval_ms: 25,
           batch_limit: 10,
           snapshot_scope: "mesh_state"}
        )

      wait_for(fn ->
        status = PeerWorker.status(worker)
        status.bootstrap_state == :needs_reseed
      end)

      status = PeerWorker.status(worker)
      assert status.bootstrapped? == false
      assert status.bootstrap_state == :needs_reseed
      assert status.last_error == :local_state_requires_reseed
      assert Watermark.inbound("peer-a@host") == %{}
      assert Agent.get(TransportStub, & &1.pull_calls) == 0
    end)
  end

  test "mesh_state snapshots exclude runtime mailbox journals and worktree leases" do
    assert :ok =
             CoreStore.put(
               :coding_agent_runtime_mailbox_journal,
               {"session-a", "msg-a"},
               %{session_id: "session-a", envelope_id: "msg-a"}
             )

    assert :ok =
             CoreStore.put(
               :mesh_worktree_leases,
               "slice-a",
               %{worktree_path: "/tmp/slice-a", lease_epoch: 2}
             )

    assert {:ok, snapshot} = Snapshot.current("mesh_state")
    entities = snapshot["entities"]

    refute Map.has_key?(entities, "runtimeMailbox")
    refute Map.has_key?(entities, "worktreeLeases")
  end

  defp wait_for(fun, attempts \\ 50)

  defp wait_for(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, attempts - 1)
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition not met in time")
end
