defmodule LemonMesh.HandoffStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store, as: CoreStore
  alias LemonCore.Store.SqliteBackend
  alias LemonMesh.HandoffStore

  defmodule HandoffStoreOpLogFailBackend do
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

  setup do
    Application.ensure_all_started(:lemon_mesh)
    HandoffStore.reset()
    :ok
  end

  test "only accepted unfinished handoffs are reconcilable" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_pending_1",
               mesh_session_id: "mesh_pending_1",
               agent_id: "reviewer",
               prompt: "Review the pending handoff",
               queue_mode: "followup"
             })

    assert Enum.map(HandoffStore.list_reconcilable(), & &1.handoff_id) == [handoff.handoff_id]

    assert {:ok, accepted} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_pending_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 100
             )

    assert accepted.delivery_state == :delivery_accepted
    assert Enum.map(HandoffStore.list_reconcilable(), & &1.handoff_id) == [handoff.handoff_id]

    assert {:ok, failed} = HandoffStore.mark_send_failed(handoff.handoff_id, 111)
    assert failed.delivery_state == :failed
    assert failed.send_failed_at_ms == 111
    assert HandoffStore.list_reconcilable() == []

    assert {:ok, completed} =
             HandoffStore.create(%{
               handoff_id: "handoff_pending_2",
               mesh_session_id: "mesh_pending_2",
               agent_id: "reviewer",
               prompt: "Review the completed handoff",
               queue_mode: "followup"
             })

    assert {:ok, _completed} = HandoffStore.mark_completed(completed.handoff_id, 222)
    assert HandoffStore.list_reconcilable() == []
  end

  test "delivery, mailbox, and blackboard bookkeeping round-trips through the wrapper" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_roundtrip_1",
               mesh_session_id: "mesh_roundtrip_1",
               agent_id: "reviewer",
               prompt: "Roundtrip bookkeeping",
               queue_mode: :steer
             })

    assert {:ok, handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_roundtrip_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 100
             )

    assert {:ok, handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_roundtrip_1", 200)

    assert handoff.delivery_state == :mailbox_persisted

    assert {:ok, handoff} =
             HandoffStore.mark_blackboard_persisted(
               handoff.handoff_id,
               "entry_roundtrip_1",
               300
             )

    assert handoff.delivery_state == :blackboard_persisted

    assert {:ok, stored} = HandoffStore.get(handoff.handoff_id)
    assert stored.queue_mode == "steer"
    assert stored.delivery_state == :blackboard_persisted
    assert stored.run_id == "run_roundtrip_1"
    assert stored.session_key == "agent:reviewer:main"
    assert stored.delivery_sent_at_ms == 100
    assert stored.message_id == "msg_roundtrip_1"
    assert stored.mailbox_persisted_at_ms == 200
    assert stored.handoff_entry_id == "entry_roundtrip_1"
    assert stored.blackboard_persisted_at_ms == 300
    assert stored.send_failed_at_ms == nil
  end

  test "runtime acceptance and apply stages round-trip through the wrapper" do
    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_runtime_1",
               mesh_session_id: "mesh_runtime_1",
               agent_id: "reviewer",
               prompt: "Track runtime lifecycle",
               queue_mode: "followup"
             })

    assert {:ok, handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_runtime_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_runtime_1", 20)

    assert {:ok, handoff} =
             HandoffStore.mark_blackboard_persisted(handoff.handoff_id, "entry_runtime_1", 30)

    assert {:ok, handoff} = HandoffStore.mark_runtime_accepted(handoff.handoff_id, 40)
    assert handoff.delivery_state == :runtime_accepted

    assert {:ok, handoff} = HandoffStore.mark_runtime_applied(handoff.handoff_id, 50)
    assert handoff.delivery_state == :runtime_applied

    assert {:ok, handoff} = HandoffStore.mark_completed(handoff.handoff_id, 60)
    assert handoff.delivery_state == :completed

    assert {:ok, stored} = HandoffStore.get(handoff.handoff_id)
    assert stored.runtime_accepted_at_ms == 40
    assert stored.runtime_applied_at_ms == 50
    assert stored.completed_at_ms == 60
  end

  test "wrapper data survives a SQLite backend restart" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "handoff_store_sqlite_#{System.unique_integer([:positive])}")

    original_state = swap_store_to_sqlite_backend(tmp_dir)

    on_exit(fn -> restore_store_backend(original_state) end)

    assert {:ok, handoff} =
             HandoffStore.create(%{
               handoff_id: "handoff_sqlite_1",
               mesh_session_id: "mesh_sqlite_1",
               agent_id: "reviewer",
               prompt: "Persist me across restart",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_sqlite_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, _handoff} =
             HandoffStore.mark_mailbox_persisted(handoff.handoff_id, "msg_sqlite_1", 20)

    restart_sqlite_backend(tmp_dir)

    assert {:ok, stored} = HandoffStore.get(handoff.handoff_id)
    assert stored.delivery_state == :mailbox_persisted
    assert stored.run_id == "run_sqlite_1"
    assert stored.message_id == "msg_sqlite_1"
    assert stored.send_failed_at_ms == nil
  end

  test "handoff create fails closed when authoritative op-log append fails" do
    capture_log(fn ->
      original_state = :sys.get_state(CoreStore)

      backend_state = %{
        delegate: original_state.backend,
        delegate_state: original_state.backend_state,
        fail_reason: :op_log_write_failed
      }

      :sys.replace_state(CoreStore, fn state ->
        %{state | backend: HandoffStoreOpLogFailBackend, backend_state: backend_state}
      end)

      on_exit(fn ->
        :sys.replace_state(CoreStore, fn _state -> original_state end)
      end)

      assert {:error, :op_log_write_failed} =
               HandoffStore.create(%{
                 handoff_id: "handoff_fail_closed_1",
                 mesh_session_id: "mesh_fail_closed_1",
                 agent_id: "reviewer",
                 prompt: "Do not mutate the read model without an op",
                 queue_mode: "followup"
               })

      assert {:error, :not_found} = HandoffStore.get("handoff_fail_closed_1")
    end)
  end

  defp swap_store_to_sqlite_backend(tmp_dir) do
    original_state = :sys.get_state(CoreStore)
    {:ok, backend_state} = SqliteBackend.init(path: tmp_dir)

    :sys.replace_state(CoreStore, fn state ->
      %{state | backend: SqliteBackend, backend_state: backend_state}
    end)

    original_state
  end

  defp restart_sqlite_backend(tmp_dir) do
    current_state = :sys.get_state(CoreStore)
    :ok = SqliteBackend.close(current_state.backend_state)
    {:ok, backend_state} = SqliteBackend.init(path: tmp_dir)

    :sys.replace_state(CoreStore, fn state ->
      %{state | backend: SqliteBackend, backend_state: backend_state}
    end)
  end

  defp restore_store_backend(original_state) do
    current_state = :sys.get_state(CoreStore)

    if current_state.backend == SqliteBackend do
      :ok = SqliteBackend.close(current_state.backend_state)
    end

    :sys.replace_state(CoreStore, fn _state -> original_state end)
  end
end
