defmodule CodingAgent.Session.PersistenceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RuntimeMailboxJournal
  alias CodingAgent.Session.Persistence
  alias CodingAgent.SessionManager

  setup do
    RuntimeMailboxJournal.reset()
    :ok
  end

  test "persist_message appends supported message types" do
    session_manager = SessionManager.new("/tmp")

    state = %{session_manager: session_manager}

    next_state =
      Persistence.persist_message(state, %Ai.Types.UserMessage{
        role: :user,
        content: "hello",
        timestamp: 1
      })

    assert SessionManager.entry_count(next_state.session_manager) == 1
  end

  test "restore_messages_from_session rebuilds serialized messages" do
    session_manager =
      SessionManager.new("/tmp")
      |> SessionManager.append_message(%{
        "role" => "user",
        "content" => "hello",
        "timestamp" => 1,
        "metadata" => %{"op_id" => "op_hello"}
      })

    [message] = Persistence.restore_messages_from_session(session_manager)
    assert %Ai.Types.UserMessage{content: "hello", timestamp: 1} = message
    assert message.metadata == %{"op_id" => "op_hello"}
  end

  test "save persists session file and updates session_file on state" do
    cwd =
      Path.join(System.tmp_dir!(), "coding-agent-session-#{System.unique_integer([:positive])}")

    session_manager = SessionManager.new(cwd)
    state = %{cwd: cwd, session_file: nil, session_manager: session_manager}

    assert {:ok, next_state} = Persistence.save(state)
    assert is_binary(next_state.session_file)
    assert File.exists?(next_state.session_file)

    File.rm_rf!(cwd)
  end

  test "persist_message finalizes runtime journal entries by metadata op_id before message_ref fallback" do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "coding-agent-persistence-#{System.unique_integer([:positive])}"
      )

    session_manager = SessionManager.new(cwd, id: "session_metadata_1")

    assert {:ok, _entry} =
             RuntimeMailboxJournal.record_acceptance(%{
               session_id: "session_metadata_1",
               mesh_session_id: "mesh_metadata_1",
               agent_id: "reviewer",
               envelope_id: "env_metadata_1",
               op_id: "op_metadata_1",
               text: "[mesh message from planner] original text",
               queue_mode: :followup,
               accepted_at_ms: 100
             })

    state = %{
      cwd: cwd,
      session_file: nil,
      session_manager: session_manager,
      mesh_mailbox_journal_pending_refs: %{
        "env_metadata_1" => %{
          message_ref: {"different text and timestamp", 999},
          op_id: "op_metadata_1"
        }
      }
    }

    next_state =
      Persistence.persist_message(state, %Ai.Types.UserMessage{
        role: :user,
        content: "[mesh message from planner] rewritten before save",
        timestamp: 777,
        metadata: %{
          "op_id" => "op_metadata_1",
          "envelope_id" => "env_metadata_1",
          "source" => "mesh_mailbox"
        }
      })

    assert next_state.mesh_mailbox_journal_pending_refs == %{}
    assert is_binary(next_state.session_file)
    assert File.exists?(next_state.session_file)

    assert {:ok, stored} = RuntimeMailboxJournal.get("session_metadata_1", "env_metadata_1")
    assert stored.applied_at_ms == 777
    assert RuntimeMailboxJournal.pending_entries("session_metadata_1") == []

    [persisted_message] = Persistence.restore_messages_from_session(next_state.session_manager)
    assert persisted_message.metadata["op_id"] == "op_metadata_1"
    assert persisted_message.metadata["envelope_id"] == "env_metadata_1"

    File.rm_rf!(cwd)
  end
end
