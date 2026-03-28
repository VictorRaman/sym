defmodule CodingAgent.SessionMeshMailboxRuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ai.Types.{AssistantMessage, Model, ModelCost, TextContent, Usage, Cost}
  alias CodingAgent.Session
  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{SessionSupervisor, Store}

  defmodule RuntimeJournalFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_reason: fail_reason}, :coding_agent_runtime_mailbox_journal, _key, _value) do
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

    Store.reset()
    CodingAgent.RuntimeMailboxJournal.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "runtime pull claims a prompt envelope and executes it when the session is idle" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime follow-up")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    {:ok, envelope} =
      LemonMesh.send_peer_message(mesh_session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review the scheduler changes"},
        metadata: %{"queue_mode" => "followup"}
      })

    wait_for_session_run(session, 2)

    state = Session.get_state(session)
    session_claimant = "session:" <> state.session_manager.header.id
    assert state.mesh_session_id == mesh_session_id
    assert :queue.len(state.follow_up_queue) == 0
    assert :queue.len(state.steering_queue) == 0

    messages = Session.get_messages(session)
    assert Enum.any?(messages, &match?(%Ai.Types.UserMessage{}, &1))
    assert Enum.any?(messages, &match?(%AssistantMessage{}, &1))

    assert {:ok, entry} =
             CodingAgent.RuntimeMailboxJournal.get(
               state.session_manager.header.id,
               envelope.message_id
             )

    assert entry.op_id == envelope.message_id
    assert is_map(entry.accepted_clock)
    assert is_integer(entry.applied_at_ms)

    assert CodingAgent.RuntimeMailboxJournal.pending_entries(state.session_manager.header.id) ==
             []

    assert {:ok, []} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_by == "reviewer"
    assert stored.claimed_by == session_claimant
  end

  test "runtime mailbox handoff metadata advances handoff to runtime_applied and completed" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime handoff completion")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    assert {:ok, handoff} =
             LemonMesh.HandoffStore.create(%{
               handoff_id: "handoff_runtime_completion_1",
               mesh_session_id: mesh_session_id,
               agent_id: "reviewer",
               prompt: "Complete the runtime handoff",
               queue_mode: "followup"
             })

    assert {:ok, _handoff} =
             LemonMesh.HandoffStore.mark_delivery(handoff.handoff_id,
               run_id: "run_runtime_completion_1",
               session_key: "agent:reviewer:main",
               delivery_sent_at_ms: 10
             )

    assert {:ok, _handoff} =
             LemonMesh.HandoffStore.mark_mailbox_persisted(
               handoff.handoff_id,
               "msg_runtime_completion_1",
               20
             )

    assert {:ok, _handoff} =
             LemonMesh.HandoffStore.mark_blackboard_persisted(
               handoff.handoff_id,
               "entry_runtime_completion_1",
               30
             )

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    assert {:ok, _envelope} =
             LemonMesh.send_peer_message(mesh_session_id, %{
               message_id: "msg_runtime_completion_1",
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Complete the runtime handoff"},
               dedupe_key: "handoff_runtime_completion_1",
               metadata: %{
                 "queue_mode" => "followup",
                 "handoff_id" => "handoff_runtime_completion_1",
                 "op_id" => "handoff_runtime_completion_1"
               }
             })

    wait_for_session_run(session, 2)

    assert {:ok, updated_handoff} = LemonMesh.HandoffStore.get("handoff_runtime_completion_1")
    assert updated_handoff.runtime_accepted_at_ms != nil
    assert updated_handoff.runtime_applied_at_ms != nil
    assert updated_handoff.completed_at_ms != nil
    assert updated_handoff.delivery_state == :completed
  end

  test "runtime pull executes idle steering envelopes immediately" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime steering")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    {:ok, envelope} =
      LemonMesh.send_peer_message(mesh_session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Switch to the safer path"},
        metadata: %{"queue_mode" => "steer"}
      })

    wait_for_session_run(session, 2)

    state = Session.get_state(session)
    session_claimant = "session:" <> state.session_manager.header.id
    assert :queue.len(state.steering_queue) == 0
    assert :queue.len(state.follow_up_queue) == 0

    assert Enum.any?(Session.get_messages(session), &match?(%Ai.Types.UserMessage{}, &1))
    assert Enum.any?(Session.get_messages(session), &match?(%AssistantMessage{}, &1))

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_by == "reviewer"
    assert stored.claimed_by == session_claimant
  end

  test "same agent sessions do not share mailbox claim identity" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime multi session claimant")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    {:ok, session_one} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    {:ok, session_two} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    {:ok, envelope} =
      LemonMesh.send_peer_message(mesh_session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "Only one session should consume this"},
        metadata: %{"queue_mode" => "followup"}
      })

    wait_for(fn ->
      length(Session.get_messages(session_one)) + length(Session.get_messages(session_two)) >= 2
    end)

    state_one = Session.get_state(session_one)
    state_two = Session.get_state(session_two)

    message_counts = [
      length(Session.get_messages(session_one)),
      length(Session.get_messages(session_two))
    ]

    assert Enum.sort(message_counts) == [0, 2]

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    session_one_claimant = "session:" <> state_one.session_manager.header.id
    session_two_claimant = "session:" <> state_two.session_manager.header.id

    assert stored.message_id == envelope.message_id
    assert stored.claimed_by in [session_one_claimant, session_two_claimant]
    refute stored.claimed_by == "reviewer"
  end

  test "runtime pull leaves the envelope pending when the session has no mesh identity" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime disabled")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_mailbox_poll_interval_ms: 10
      )

    {:ok, envelope} =
      LemonMesh.send_peer_message(mesh_session_id, %{
        from_agent: "planner",
        to_agent: "reviewer",
        channel: "mesh",
        payload_kind: "prompt",
        payload: %{"prompt" => "This should stay pending"},
        metadata: %{"queue_mode" => "followup"}
      })

    Process.sleep(40)

    state = Session.get_state(session)
    assert state.mesh_session_id == nil
    assert :queue.len(state.follow_up_queue) == 0
    assert :queue.len(state.steering_queue) == 0

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_at_ms == nil
  end

  test "runtime pull does not ack when durable acceptance journal write fails" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime journal failure")
    mesh_session_id = LemonMesh.session_id(mesh_pid)

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    original_state =
      swap_store_backend(RuntimeJournalFailBackend, fail_reason: :journal_write_failed)

    on_exit(fn -> restore_store_backend(original_state) end)

    {envelope, log} =
      capture_log(fn ->
        {:ok, envelope} =
          LemonMesh.send_peer_message(mesh_session_id, %{
            from_agent: "planner",
            to_agent: "reviewer",
            channel: "mesh",
            payload_kind: "prompt",
            payload: %{"prompt" => "Do not ack this if journal fails"},
            metadata: %{"queue_mode" => "followup"}
          })

        Process.sleep(1_000)
        send(self(), {:runtime_journal_failure_envelope, envelope})
      end)
      |> then(fn log ->
        receive do
          {:runtime_journal_failure_envelope, envelope} -> {envelope, log}
        end
      end)

    state = Session.get_state(session)
    assert :queue.len(state.follow_up_queue) == 0
    assert :queue.len(state.steering_queue) == 0

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_at_ms == nil
    assert log =~ "journal_write_failed"
  end

  test "session startup replays one unapplied runtime mailbox journal entry and marks it applied" do
    accepted_at_ms = System.system_time(:millisecond)

    assert {:ok, _entry} =
             CodingAgent.RuntimeMailboxJournal.record_acceptance(%{
               session_id: "session-replay-1",
               mesh_session_id: "mesh_replay_1",
               agent_id: "reviewer",
               envelope_id: "msg_replay_1",
               text: "[mesh message from planner] Replay me",
               queue_mode: :followup,
               accepted_at_ms: accepted_at_ms
             })

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        session_id: "session-replay-1",
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: "mesh_replay_1",
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    wait_for_session_run(session, 2)

    state = Session.get_state(session)
    assert :queue.len(state.follow_up_queue) == 0

    assert {:ok, entry} =
             CodingAgent.RuntimeMailboxJournal.get(
               state.session_manager.header.id,
               "msg_replay_1"
             )

    assert is_integer(entry.applied_at_ms)
    assert CodingAgent.RuntimeMailboxJournal.pending_entries("session-replay-1") == []
  end

  test "session startup replays a legacy journal entry that predates agent_id" do
    accepted_at_ms = System.system_time(:millisecond)

    assert :ok =
             CoreStore.put(
               :coding_agent_runtime_mailbox_journal,
               {"session-replay-legacy-1", "msg_replay_legacy_1"},
               %{
                 session_id: "session-replay-legacy-1",
                 mesh_session_id: "mesh_replay_legacy_1",
                 envelope_id: "msg_replay_legacy_1",
                 op_id: "msg_replay_legacy_1",
                 text: "[mesh message from planner] Replay legacy entry",
                 queue_mode: :followup,
                 accepted_clock: %{},
                 accepted_at_ms: accepted_at_ms,
                 applied_clock: nil,
                 applied_at_ms: nil
               }
             )

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        session_id: "session-replay-legacy-1",
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: "mesh_replay_legacy_1",
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    wait_for_session_run(session, 2)

    state = Session.get_state(session)
    assert :queue.len(state.follow_up_queue) == 0

    assert {:ok, entry} =
             CodingAgent.RuntimeMailboxJournal.get(
               state.session_manager.header.id,
               "msg_replay_legacy_1"
             )

    assert entry.agent_id == ""
    assert is_integer(entry.applied_at_ms)
    assert CodingAgent.RuntimeMailboxJournal.pending_entries("session-replay-legacy-1") == []
  end

  test "acknowledged journal-backed prompts replay after restart when save failed before apply" do
    {:ok, mesh_pid} = LemonMesh.start_session(goal: "runtime save failure replay")
    mesh_session_id = LemonMesh.session_id(mesh_pid)
    session_id = "session-restart-1"

    blocked_dir =
      Path.join(System.tmp_dir!(), "mesh_runtime_blocked_#{System.unique_integer([:positive])}")

    assert :ok = File.write(blocked_dir, "not-a-directory")

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        session_id: session_id,
        session_file: Path.join(blocked_dir, "session.jsonl"),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    envelope =
      capture_log_result(fn ->
        {:ok, envelope} =
          LemonMesh.send_peer_message(mesh_session_id, %{
            from_agent: "planner",
            to_agent: "reviewer",
            channel: "mesh",
            payload_kind: "prompt",
            payload: %{"prompt" => "Recover me after restart"},
            metadata: %{"queue_mode" => "followup"}
          })

        wait_for(fn ->
          state = Session.get_state(session)
          not state.is_streaming and length(Session.get_messages(session)) >= 2
        end)

        envelope
      end)

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               mesh_session_id,
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_at_ms != nil

    assert {:ok, entry} = CodingAgent.RuntimeMailboxJournal.get(session_id, envelope.message_id)
    assert entry.op_id == envelope.message_id
    assert is_map(entry.accepted_clock)
    assert entry.applied_at_ms == nil
    assert length(CodingAgent.RuntimeMailboxJournal.pending_entries(session_id)) == 1

    GenServer.stop(session, :normal)

    {:ok, restarted_session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        session_id: session_id,
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("idle")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    wait_for_session_run(restarted_session, 2)

    assert {:ok, replayed_entry} =
             CodingAgent.RuntimeMailboxJournal.get(session_id, envelope.message_id)

    assert is_integer(replayed_entry.applied_at_ms)
    assert CodingAgent.RuntimeMailboxJournal.pending_entries(session_id) == []
  end

  defp swap_store_backend(backend, opts) do
    original_state = :sys.get_state(CoreStore)

    backend_state = %{
      delegate: original_state.backend,
      delegate_state: original_state.backend_state,
      fail_reason: Keyword.get(opts, :fail_reason, :backend_failed)
    }

    :sys.replace_state(CoreStore, fn state ->
      %{state | backend: backend, backend_state: backend_state}
    end)

    original_state
  end

  defp restore_store_backend(original_state) do
    :sys.replace_state(CoreStore, fn _state -> original_state end)
  end

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 2,
        cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
      },
      stop_reason: :stop,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, stream_from_response(response)}
    end
  end

  defp stream_from_response(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})
      Ai.EventStream.push(stream, {:text_start, 0, response})
      Ai.EventStream.push(stream, {:text_delta, 0, "idle", response})
      Ai.EventStream.push(stream, {:text_end, 0, response})
      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp wait_for_session_run(session, min_messages) do
    wait_for(fn ->
      state = Session.get_state(session)
      not state.is_streaming and length(Session.get_messages(session)) >= min_messages
    end)
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

  defp wait_for(fun, attempts \\ 40)

  defp wait_for(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_for(fun, attempts - 1)
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition not met in time")
end
