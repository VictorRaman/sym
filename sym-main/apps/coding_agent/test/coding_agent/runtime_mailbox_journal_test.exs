defmodule CodingAgent.RuntimeMailboxJournalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RuntimeMailboxJournal
  alias LemonCore.Store, as: CoreStore
  alias LemonCore.Store.SqliteBackend
  alias LemonMesh.NodeIdentity

  setup do
    Application.ensure_all_started(:lemon_core)
    RuntimeMailboxJournal.reset()
    :ok
  end

  test "record_acceptance and mark_applied round-trip through the wrapper" do
    assert {:ok, entry} =
             RuntimeMailboxJournal.record_acceptance(%{
               session_id: "session_wrapper_1",
               mesh_session_id: "mesh_wrapper_1",
               agent_id: "reviewer",
               envelope_id: "env_wrapper_1",
               text: "Review this runtime prompt",
               queue_mode: :collect,
               accepted_at_ms: 100
             })

    assert entry.queue_mode == :collect
    assert entry.op_id == "env_wrapper_1"
    assert entry.accepted_clock == %{}
    assert RuntimeMailboxJournal.pending_count("session_wrapper_1") == 1

    assert :ok = RuntimeMailboxJournal.mark_applied("session_wrapper_1", "env_wrapper_1", 200)
    assert {:ok, stored} = RuntimeMailboxJournal.get("session_wrapper_1", "env_wrapper_1")
    assert stored.applied_at_ms == 200
    assert stored.applied_clock[NodeIdentity.current_node_id()] == 1
    assert RuntimeMailboxJournal.pending_entries("session_wrapper_1") == []
  end

  test "wrapper data survives a SQLite backend restart" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runtime_mailbox_journal_sqlite_#{System.unique_integer([:positive])}"
      )

    original_state = swap_store_to_sqlite_backend(tmp_dir)
    on_exit(fn -> restore_store_backend(original_state) end)

    assert {:ok, _entry} =
             RuntimeMailboxJournal.record_acceptance(%{
               session_id: "session_sqlite_1",
               mesh_session_id: "mesh_sqlite_1",
               agent_id: "reviewer",
               envelope_id: "env_sqlite_1",
               text: "Persist me across sqlite restart",
               queue_mode: :followup,
               accepted_at_ms: 123
             })

    restart_sqlite_backend(tmp_dir)

    assert {:ok, stored} = RuntimeMailboxJournal.get("session_sqlite_1", "env_sqlite_1")
    assert stored.text == "Persist me across sqlite restart"
    assert stored.op_id == "env_sqlite_1"
    assert stored.accepted_clock == %{}
    assert stored.accepted_at_ms == 123
    assert stored.applied_at_ms == nil
  end

  test "pending_entries drops malformed legacy rows instead of crashing session startup" do
    malformed_key = {"session_malformed_1", "env_malformed_1"}

    assert :ok =
             CoreStore.put(
               :coding_agent_runtime_mailbox_journal,
               malformed_key,
               %{
                 session_id: "session_malformed_1",
                 mesh_session_id: "mesh_malformed_1",
                 agent_id: "reviewer",
                 envelope_id: "env_malformed_1",
                 accepted_clock: %{},
                 accepted_at_ms: 123,
                 applied_clock: nil,
                 applied_at_ms: nil
               }
             )

    assert RuntimeMailboxJournal.pending_entries("session_malformed_1") == []
    assert {:error, :not_found} = RuntimeMailboxJournal.get("session_malformed_1", "env_malformed_1")
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
