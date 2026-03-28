defmodule LemonMesh.PeerMailboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{Op, OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.{Projector, Watermark}

  defmodule PeerMailboxSessionMetadataFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_reason: fail_reason}, :mesh_sessions, _key, _value) do
      {:error, fail_reason}
    end

    def put(%{delegate: delegate, delegate_state: delegate_state} = state, table, key, value) do
      case delegate.put(delegate_state, table, key, value) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def get(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.get(delegate_state, table, key) do
        {:ok, value, next_delegate_state} ->
          {:ok, value, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def delete(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.delete(delegate_state, table, key) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def list(%{delegate: delegate, delegate_state: delegate_state} = state, table) do
      case delegate.list(delegate_state, table) do
        {:ok, entries, next_delegate_state} ->
          {:ok, entries, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule PeerMailboxOpLogFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_reason: fail_reason}, :mesh_op_log, _key, _value) do
      {:error, fail_reason}
    end

    def put(%{delegate: delegate, delegate_state: delegate_state} = state, table, key, value) do
      case delegate.put(delegate_state, table, key, value) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def get(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.get(delegate_state, table, key) do
        {:ok, value, next_delegate_state} ->
          {:ok, value, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def delete(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.delete(delegate_state, table, key) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def list(%{delegate: delegate, delegate_state: delegate_state} = state, table) do
      case delegate.list(delegate_state, table) do
        {:ok, entries, next_delegate_state} ->
          {:ok, entries, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule PeerMailboxLockTableDeletedBackend do
    @behaviour LemonCore.Store.Backend

    @lock_table :mesh_peer_mailbox_locks

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{delegate: delegate, delegate_state: delegate_state} = state, table, key, value) do
      case delegate.put(delegate_state, table, key, value) do
        {:ok, next_delegate_state} ->
          next_state =
            state
            |> Map.put(:delegate_state, next_delegate_state)
            |> maybe_delete_lock_table(table)

          {:ok, next_state}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def get(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.get(delegate_state, table, key) do
        {:ok, value, next_delegate_state} ->
          {:ok, value, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def delete(%{delegate: delegate, delegate_state: delegate_state} = state, table, key) do
      case delegate.delete(delegate_state, table, key) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def list(%{delegate: delegate, delegate_state: delegate_state} = state, table) do
      case delegate.list(delegate_state, table) do
        {:ok, entries, next_delegate_state} ->
          {:ok, entries, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp maybe_delete_lock_table(%{deleted?: true} = state, _table), do: state

    defp maybe_delete_lock_table(%{delete_on_table: table} = state, table) do
      if :ets.whereis(@lock_table) != :undefined do
        :ets.delete(@lock_table)
      end

      Map.put(state, :deleted?, true)
    end

    defp maybe_delete_lock_table(state, _table), do: state
  end

  setup do
    Application.ensure_all_started(:lemon_mesh)

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)

    Store.reset()
    OpLog.reset()
    Watermark.reset()
    :ok
  end

  test "send_peer_message/2 fails closed when authoritative op-log append fails" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox op-log fail closed")
      session_id = LemonMesh.session_id(pid)

      original_state =
        swap_store_backend(PeerMailboxOpLogFailBackend,
          fail_reason: :op_log_write_failed
        )

      on_exit(fn -> restore_store_backend(original_state) end)

      assert {:error, :op_log_write_failed} =
               LemonMesh.send_peer_message(session_id, %{
                 from_agent: "planner",
                 to_agent: "reviewer",
                 channel: "mesh",
                 payload_kind: "prompt",
                 payload: %{"prompt" => "Do not write read model without an op"}
               })

      assert {:ok, []} =
               LemonMesh.list_peer_messages(session_id,
                 to_agent: "reviewer",
                 pending_only: false
               )
    end)
  end

  test "send_peer_message/2 persists a pending envelope for a running session" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox running session")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review the scheduler changes"}
      })

    assert envelope.session_id == session_id
    assert envelope.from_agent == "planner"
    assert envelope.to_agent == "reviewer"
    assert envelope.payload_kind == "prompt"
    assert envelope.acknowledged_at_ms == nil

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    assert pending.message_id == envelope.message_id
    assert pending.payload == %{"prompt" => "Review the scheduler changes"}
  end

  test "send_peer_message/2 works for a stopped persisted session" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox stopped session")
    session_id = LemonMesh.session_id(pid)

    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "control_plane",
        to_agent: "reviewer",
        channel: "control_plane_mesh",
        payload_kind: "handoff",
        payload: %{"prompt" => "Review persisted mailbox message"}
      })

    assert envelope.session_id == session_id
    assert envelope.to_agent == "reviewer"

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    assert pending.message_id == envelope.message_id

    snapshot = LemonMesh.get_session!(session_id)
    assert snapshot.status == :stopped
  end

  test "ack_peer_message/3 marks a message acknowledged and hides it from pending queries" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox ack")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "implementer",
        channel: "mesh",
        payload_kind: "fact",
        payload: %{"summary" => "Scheduler boundary identified"}
      })

    assert {:ok, acknowledged} =
             LemonMesh.ack_peer_message(session_id, envelope.message_id,
               acknowledged_by: "implementer"
             )

    assert acknowledged.message_id == envelope.message_id
    assert acknowledged.acknowledged_by == "implementer"
    assert is_integer(acknowledged.acknowledged_at_ms)

    assert {:ok, []} = LemonMesh.list_peer_messages(session_id, to_agent: "implementer")

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               session_id,
               to_agent: "implementer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_by == "implementer"
  end

  test "send_peer_message/2 still succeeds when session metadata refresh fails" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox metadata failure send")
    session_id = LemonMesh.session_id(pid)

    original_state =
      swap_store_backend(PeerMailboxSessionMetadataFailBackend,
        fail_reason: :metadata_write_failed
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    envelope =
      capture_log_result(fn ->
        assert {:ok, envelope} =
                 LemonMesh.send_peer_message(session_id, %{
                   from_agent: "planner",
                   to_agent: "reviewer",
                   channel: "mesh",
                   payload_kind: "prompt",
                   payload: %{"prompt" => "Persist even if metadata refresh fails"}
                 })

        envelope
      end)

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    assert pending.message_id == envelope.message_id
  end

  test "ack_peer_message/3 returns an error for unknown messages" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox missing ack")
    session_id = LemonMesh.session_id(pid)

    assert {:error, :message_not_found} =
             LemonMesh.ack_peer_message(session_id, "msg_missing", acknowledged_by: "reviewer")
  end

  test "ack_peer_message/3 still succeeds when session metadata refresh fails" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox metadata failure ack")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Ack should stay successful"}
      })

    original_state =
      swap_store_backend(PeerMailboxSessionMetadataFailBackend,
        fail_reason: :metadata_write_failed
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    acknowledged =
      capture_log_result(fn ->
        assert {:ok, acknowledged} =
                 LemonMesh.ack_peer_message(
                   session_id,
                   envelope.message_id,
                   acknowledged_by: "reviewer"
                 )

        acknowledged
      end)

    assert acknowledged.message_id == envelope.message_id

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.acknowledged_by == "reviewer"
  end

  test "claim_peer_messages/2 hides actively leased messages from pending queries" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox claim")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this"}
      })

    assert {:ok, [claimed]} =
             LemonMesh.claim_peer_messages(
               session_id,
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert claimed.message_id == envelope.message_id
    assert claimed.claimed_by == "session:reviewer"
    assert is_integer(claimed.claimed_at_ms)
    assert is_integer(claimed.claim_expires_at_ms)

    assert {:ok, []} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.claimed_by == "session:reviewer"
  end

  test "claim_peer_messages/2 makes expired leases visible again" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox lease expiry")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this after expiry"}
      })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               session_id,
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 10
             )

    Process.sleep(20)

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    assert pending.message_id == envelope.message_id
    assert pending.claimed_by == "session:reviewer"
    assert pending.claim_expires_at_ms != nil
  end

  test "claim_peer_messages/2 survives lock table deletion during cleanup" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox lock cleanup race")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Claim even if lock table disappears"}
      })

    original_state =
      swap_store_backend(PeerMailboxLockTableDeletedBackend,
        delete_on_table: :mesh_peer_mailboxes,
        deleted?: false
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    assert {:ok, [claimed]} =
             LemonMesh.claim_peer_messages(
               session_id,
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert claimed.message_id == envelope.message_id
  end

  test "concurrent claim_peer_messages/2 only lets one claimant win" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox atomic claim")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Atomic claim"}
      })

    claim_task = fn claimed_by ->
      Task.async(fn ->
        receive do
          :go ->
            LemonMesh.claim_peer_messages(session_id,
              to_agent: "reviewer",
              claimed_by: claimed_by
            )
        end
      end)
    end

    task_one = claim_task.("session:one")
    task_two = claim_task.("session:two")

    send(task_one.pid, :go)
    send(task_two.pid, :go)

    results = [Task.await(task_one, 1_000), Task.await(task_two, 1_000)]

    assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, []})) == 1

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(session_id, to_agent: "reviewer", pending_only: false)

    assert stored.message_id == envelope.message_id
    assert stored.claimed_by in ["session:one", "session:two"]
  end

  test "peer mailbox lifecycle emits authoritative ops and rebuilds from the op log" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox authoritative lifecycle")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Authoritative mailbox lifecycle"}
      })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               session_id,
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert {:ok, acknowledged} =
             LemonMesh.ack_peer_message(
               session_id,
               envelope.message_id,
               acknowledged_by: "reviewer",
               expected_to_agent: "reviewer",
               expected_claimed_by: "session:reviewer"
             )

    ops = OpLog.list(entity_type: "peer_mailbox", entity_id: envelope.message_id)

    assert Enum.map(ops, & &1.op_type) == [
             "message_created",
             "message_claimed",
             "message_acked"
           ]

    last_op = List.last(ops)
    assert Watermark.local()[last_op.origin_node_id] == 3

    assert :ok = CoreStore.delete(:mesh_peer_mailboxes, session_id)

    assert {:ok, []} =
             LemonMesh.list_peer_messages(session_id, to_agent: "reviewer", pending_only: false)

    assert {:ok, rebuilt_messages} = Projector.rebuild_entity("peer_mailbox", session_id)

    assert {:ok, [rebuilt]} =
             LemonMesh.list_peer_messages(session_id, to_agent: "reviewer", pending_only: false)

    assert length(rebuilt_messages) == 1
    assert rebuilt.message_id == envelope.message_id
    assert rebuilt.acknowledged_by == acknowledged.acknowledged_by
    assert rebuilt.claimed_by == "session:reviewer"
  end

  test "projector ignores stale mailbox ack when a newer lease epoch already won" do
    created =
      Op.new(%{
        op_id: "msg_merge_1:message_created",
        origin_node_id: "node-a",
        entity_type: "peer_mailbox",
        entity_id: "msg_merge_1",
        op_type: "message_created",
        causal_clock: %{"node-a" => 1},
        payload: %{
          message_id: "msg_merge_1",
          session_id: "mesh_merge_1",
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          origin_node_id: "node-a",
          vector_clock: %{"node-a" => 1},
          delivery_epoch: 0,
          payload_kind: "prompt",
          payload_ref: nil,
          payload: %{"prompt" => "Keep newest claim winner"},
          dedupe_key: "msg_merge_1",
          inserted_at_ms: 10,
          claimed_at_ms: nil,
          claim_expires_at_ms: nil,
          claimed_by: nil,
          lease_epoch: 0,
          acknowledged_at_ms: nil,
          acknowledged_by: nil,
          metadata: %{}
        }
      })

    claim_one =
      Op.new(%{
        op_id: "msg_merge_1:message_claimed:1",
        origin_node_id: "node-a",
        entity_type: "peer_mailbox",
        entity_id: "msg_merge_1",
        op_type: "message_claimed",
        causal_clock: %{"node-a" => 2},
        lease_epoch: 1,
        payload: %{
          message_id: "msg_merge_1",
          session_id: "mesh_merge_1",
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          origin_node_id: "node-a",
          vector_clock: %{"node-a" => 1},
          delivery_epoch: 0,
          payload_kind: "prompt",
          payload_ref: nil,
          payload: %{"prompt" => "Keep newest claim winner"},
          dedupe_key: "msg_merge_1",
          inserted_at_ms: 10,
          claimed_at_ms: 20,
          claim_expires_at_ms: 120,
          claimed_by: "session:one",
          lease_epoch: 1,
          acknowledged_at_ms: nil,
          acknowledged_by: nil,
          metadata: %{"claim_origin_node_id" => "node-a"}
        }
      })

    claim_two =
      Op.new(%{
        op_id: "msg_merge_1:message_claimed:2",
        origin_node_id: "node-b",
        entity_type: "peer_mailbox",
        entity_id: "msg_merge_1",
        op_type: "message_claimed",
        causal_clock: %{"node-b" => 1},
        lease_epoch: 2,
        payload: %{
          message_id: "msg_merge_1",
          session_id: "mesh_merge_1",
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          origin_node_id: "node-a",
          vector_clock: %{"node-a" => 1},
          delivery_epoch: 0,
          payload_kind: "prompt",
          payload_ref: nil,
          payload: %{"prompt" => "Keep newest claim winner"},
          dedupe_key: "msg_merge_1",
          inserted_at_ms: 10,
          claimed_at_ms: 30,
          claim_expires_at_ms: 130,
          claimed_by: "session:two",
          lease_epoch: 2,
          acknowledged_at_ms: nil,
          acknowledged_by: nil,
          metadata: %{"claim_origin_node_id" => "node-b"}
        }
      })

    stale_ack =
      Op.new(%{
        op_id: "msg_merge_1:message_acked:1",
        origin_node_id: "node-a",
        entity_type: "peer_mailbox",
        entity_id: "msg_merge_1",
        op_type: "message_acked",
        causal_clock: %{"node-a" => 3},
        lease_epoch: 1,
        payload: %{
          message_id: "msg_merge_1",
          session_id: "mesh_merge_1",
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          origin_node_id: "node-a",
          vector_clock: %{"node-a" => 1},
          delivery_epoch: 0,
          payload_kind: "prompt",
          payload_ref: nil,
          payload: %{"prompt" => "Keep newest claim winner"},
          dedupe_key: "msg_merge_1",
          inserted_at_ms: 10,
          claimed_at_ms: 20,
          claim_expires_at_ms: 120,
          claimed_by: "session:one",
          lease_epoch: 1,
          acknowledged_at_ms: 40,
          acknowledged_by: "reviewer",
          metadata: %{"claim_origin_node_id" => "node-a"}
        }
      })

    assert {:ok, _messages} = Projector.project(created)
    assert {:ok, _messages} = Projector.project(claim_one)
    assert {:ok, _messages} = Projector.project(claim_two)
    assert {:ok, _messages} = Projector.project(stale_ack)

    assert [stored] = Store.list_peer_messages("mesh_merge_1")

    assert stored.message_id == "msg_merge_1"
    assert stored.claimed_by == "session:two"
    assert stored.lease_epoch == 2
    assert stored.acknowledged_at_ms == nil
  end

  test "ack_peer_message/3 can require the expected claimant" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox claimant guard")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this"}
      })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               session_id,
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert {:error, :message_not_found} =
             LemonMesh.ack_peer_message(
               session_id,
               envelope.message_id,
               acknowledged_by: "reviewer",
               expected_to_agent: "reviewer",
               expected_claimed_by: "session:other"
             )

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_at_ms == nil
    assert stored.claimed_by == "session:reviewer"
  end

  test "ack_peer_message/3 can require the expected recipient" do
    {:ok, pid} = LemonMesh.start_session(goal: "Peer mailbox recipient guard")
    session_id = LemonMesh.session_id(pid)

    {:ok, envelope} =
      LemonMesh.send_peer_message(session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this"}
      })

    assert {:error, :message_not_found} =
             LemonMesh.ack_peer_message(
               session_id,
               envelope.message_id,
               acknowledged_by: "implementer",
               expected_to_agent: "implementer"
             )

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    assert pending.message_id == envelope.message_id
    assert pending.acknowledged_at_ms == nil
  end

  defp swap_store_backend(backend, opts) do
    original_state = :sys.get_state(CoreStore)

    backend_state =
      Map.merge(%{
        delegate: original_state.backend,
        delegate_state: original_state.backend_state,
        fail_reason: Keyword.get(opts, :fail_reason, :backend_failed)
      }, Map.new(opts))

    :sys.replace_state(CoreStore, fn state ->
      %{state | backend: backend, backend_state: backend_state}
    end)

    original_state
  end

  defp restore_store_backend(original_state) do
    :sys.replace_state(CoreStore, fn _state -> original_state end)
  end

  defp capture_log_result(fun) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    capture_log(fn ->
      send(parent, {ref, fun.()})
    end)

    receive do
      {^ref, value} -> value
    end
  end
end
