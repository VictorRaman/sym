defmodule LemonControlPlane.MeshAgentMessageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
  alias CodingAgent.Session
  alias LemonControlPlane.Methods.MeshAgentMessage
  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.Watermark

  defmodule MeshAgentMessageRouterStub do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            owner: nil,
            result:
              {:ok,
               %{
                 run_id: "run_stub_1",
                 session_key: "agent:reviewer:main",
                 selector: :latest,
                 fanout_count: 0
               }}
          }
        end,
        name: __MODULE__
      )
    end

    def configure(owner, result \\ nil) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | owner: owner,
            result: result || state.result
        }
      end)
    end

    def send_to_agent(agent_id, prompt, opts) do
      Agent.get(__MODULE__, fn %{owner: owner, result: result} ->
        if is_pid(owner) do
          send(owner, {:router_send_to_agent, agent_id, prompt, opts})
        end

        result
      end)
    end
  end

  defmodule MeshAgentMessageSubmitterStub do
    def submit(request) do
      if pid = Process.get(:mesh_agent_message_submitter_pid) do
        send(pid, {:submitted_request, request})
      end

      {:ok, "run_submitter_stub"}
    end
  end

  defmodule MeshAgentMessageTableFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_table: fail_table, fail_reason: fail_reason}, fail_table, _key, _value) do
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

  defmodule MeshAgentMessageExistingRecordPutFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_table: fail_table} = state, table, key, value) when table == fail_table do
      do_put_with_existing_check(state, table, key, value)
    end

    def put(%{delegate: delegate, delegate_state: delegate_state} = state, table, key, value) do
      case delegate.put(delegate_state, table, key, value) do
        {:ok, next_delegate_state} ->
          {:ok, %{state | delegate_state: next_delegate_state}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp do_put_with_existing_check(
           %{fail_reason: fail_reason, delegate: delegate, delegate_state: delegate_state} = state,
           table,
           key,
           value
         ) do
      case delegate.get(delegate_state, table, key) do
        {:ok, nil, next_delegate_state} ->
          case delegate.put(next_delegate_state, table, key, value) do
            {:ok, latest_delegate_state} ->
              {:ok, %{state | delegate_state: latest_delegate_state}}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _existing, _next_delegate_state} ->
          {:error, fail_reason}

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

  defmodule MeshAgentMessageDeliveryPutFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(
          %{fail_table: fail_table, fail_reason: fail_reason, delegate: delegate,
            delegate_state: delegate_state} = state,
          table,
          key,
          value
        )
        when table == fail_table and is_map(value) do
      delivery_sent_at_ms = value[:delivery_sent_at_ms] || value["delivery_sent_at_ms"]

      if is_integer(delivery_sent_at_ms) do
        {:error, fail_reason}
      else
        case delegate.put(delegate_state, table, key, value) do
          {:ok, next_delegate_state} ->
            {:ok, %{state | delegate_state: next_delegate_state}}

          {:error, reason} ->
            {:error, reason}
        end
      end
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
    start_supervised!(MeshAgentMessageRouterStub)
    previous_submitter = Application.get_env(:lemon_router, :agent_inbox_submitter)

    Application.put_env(
      :lemon_control_plane,
      :mesh_agent_message_router,
      MeshAgentMessageRouterStub
    )

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)

    Store.reset()
    LemonMesh.HandoffStore.reset()
    OpLog.reset()
    Watermark.reset()

    on_exit(fn ->
      Application.delete_env(:lemon_control_plane, :mesh_agent_message_router)

      case previous_submitter do
        nil -> Application.delete_env(:lemon_router, :agent_inbox_submitter)
        value -> Application.put_env(:lemon_router, :agent_inbox_submitter, value)
      end

      Process.delete(:mesh_agent_message_submitter_pid)
    end)

    MeshAgentMessageRouterStub.configure(self())

    {:ok, pid} = LemonMesh.start_session(goal: "Mesh agent message test")

    {:ok, mesh_session_id: LemonMesh.session_id(pid)}
  end

  test "forwards agent message through LemonRouter and appends a handoff entry", %{
    mesh_session_id: mesh_session_id
  } do
    assert {:ok, payload} =
             MeshAgentMessage.handle(
               %{
                 "meshSessionId" => mesh_session_id,
                 "agentId" => "reviewer",
                 "prompt" => "Review the scheduler changes",
                 "queueMode" => "steer",
                 "meta" => %{"trace" => "mesh-test"}
               },
               %{}
             )

    assert payload["runId"] == "run_stub_1"
    assert payload["sessionKey"] == "agent:reviewer:main"
    assert payload["selector"] == "latest"
    assert is_binary(payload["messageId"])
    assert is_binary(payload["handoffEntryId"])

    assert_receive {:router_send_to_agent, "reviewer", "Review the scheduler changes", opts}
    assert opts[:queue_mode] == :steer
    assert opts[:meta]["trace"] == "mesh-test"
    assert opts[:meta]["mesh_session_id"] == mesh_session_id
    assert opts[:source] == "control_plane_mesh"

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")
    assert pending.message_id == payload["messageId"]
    assert pending.from_agent == "control_plane"
    assert pending.to_agent == "reviewer"
    assert pending.channel == "control_plane_mesh"
    assert pending.payload_kind == "prompt"
    assert pending.payload == %{"prompt" => "Review the scheduler changes"}
    assert pending.metadata["trace"] == "mesh-test"
    assert pending.metadata["queue_mode"] == "steer"

    assert {:ok, entries} = LemonMesh.list_blackboard_entries(mesh_session_id)
    assert length(entries) == 1

    [entry] = entries
    assert entry.entry_id == payload["handoffEntryId"]
    assert entry.kind == "handoff"
    assert entry.author == "control_plane"
    assert entry.scope == "mesh"
    assert entry.body["target_agent"] == "reviewer"
    assert entry.body["prompt"] == "Review the scheduler changes"
    assert entry.body["run_id"] == nil
    assert entry.body["session_key"] == nil
    assert entry.body["queue_mode"] == "steer"
  end

  test "returns durable success when router fast path fails", %{
    mesh_session_id: mesh_session_id
  } do
    MeshAgentMessageRouterStub.configure(self(), {:error, :router_unavailable})

    assert {:ok, payload} =
             MeshAgentMessage.handle(
               %{
                 "meshSessionId" => mesh_session_id,
                 "agentId" => "reviewer",
                 "prompt" => "Review this"
               },
               %{}
             )

    assert payload["deliveryAccepted"] == false
    assert payload["mailboxPersisted"] == true
    assert payload["blackboardPersisted"] == true
    assert is_binary(payload["messageId"])
    assert is_binary(payload["handoffEntryId"])

    assert_receive {:router_send_to_agent, "reviewer", "Review this", _opts}

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")
    assert pending.message_id == payload["messageId"]

    assert {:ok, [entry]} = LemonMesh.list_blackboard_entries(mesh_session_id)
    assert entry.entry_id == payload["handoffEntryId"]
  end

  test "fails closed when mailbox persistence fails before delivery", %{
    mesh_session_id: mesh_session_id
  } do
    original_state =
      swap_store_backend(MeshAgentMessageTableFailBackend,
        fail_table: :mesh_peer_mailboxes,
        fail_reason: :mailbox_write_failed
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    on_exit(fn -> restore_store_backend(original_state) end)

    on_exit(fn -> restore_store_backend(original_state) end)

    details =
      capture_log_result(fn ->
        assert {:error, {:internal_error, "Failed to record mesh handoff", details}} =
                 MeshAgentMessage.handle(
                   %{
                     "meshSessionId" => mesh_session_id,
                     "agentId" => "reviewer",
                     "prompt" => "Deliver even if mailbox persist fails"
                   },
                   %{}
                 )

        details
      end)

    assert details =~ "mailbox_persist_failed"
    refute_receive {:router_send_to_agent, "reviewer", "Deliver even if mailbox persist fails",
                    _opts},
                   50

    assert {:ok, []} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")

    assert [{handoff_id, _}] = LemonCore.Store.list(:mesh_handoff_ops)
    assert {:ok, handoff} = LemonMesh.HandoffStore.get(handoff_id)
    assert handoff.run_id == nil
    assert handoff.delivery_sent_at_ms == nil
    assert handoff.mailbox_persisted_at_ms == nil
    assert handoff.blackboard_persisted_at_ms == nil
    assert handoff.completed_at_ms == nil
  end

  test "fails closed when blackboard persistence fails before delivery", %{
    mesh_session_id: mesh_session_id
  } do
    original_state =
      swap_store_backend(MeshAgentMessageTableFailBackend,
        fail_table: :mesh_blackboards,
        fail_reason: :blackboard_write_failed
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    details =
      capture_log_result(fn ->
        assert {:error, {:internal_error, "Failed to record mesh handoff", details}} =
                 MeshAgentMessage.handle(
                   %{
                     "meshSessionId" => mesh_session_id,
                     "agentId" => "reviewer",
                     "prompt" => "Persist mailbox even if blackboard fails"
                   },
                   %{}
                 )

        details
      end)

    assert details =~ "blackboard_persist_failed"
    refute_receive {:router_send_to_agent, "reviewer", "Persist mailbox even if blackboard fails",
                    _opts},
                   50

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")
    assert pending.message_id != nil

    assert [{handoff_id, _}] = LemonCore.Store.list(:mesh_handoff_ops)
    assert {:ok, handoff} = LemonMesh.HandoffStore.get(handoff_id)
    assert handoff.run_id == nil
    assert handoff.delivery_sent_at_ms == nil
    assert handoff.mailbox_persisted_at_ms != nil
    assert handoff.blackboard_persisted_at_ms == nil
    assert handoff.completed_at_ms == nil
  end

  test "appends handoff entries for a stopped persisted mesh session", %{
    mesh_session_id: mesh_session_id
  } do
    assert {:ok, pid} = LemonMesh.session_pid(mesh_session_id)
    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    assert {:ok, payload} =
             MeshAgentMessage.handle(
               %{
                 "meshSessionId" => mesh_session_id,
                 "agentId" => "reviewer",
                 "prompt" => "Review persisted session handoff"
               },
               %{}
             )

    assert payload["runId"] == "run_stub_1"
    assert is_binary(payload["messageId"])
    assert_receive {:router_send_to_agent, "reviewer", "Review persisted session handoff", _opts}

    assert {:ok, [pending]} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")
    assert pending.message_id == payload["messageId"]

    assert {:ok, entries} = LemonMesh.list_blackboard_entries(mesh_session_id)
    assert length(entries) == 1
    assert hd(entries).entry_id == payload["handoffEntryId"]
  end

  test "returns success when delivery bookkeeping fails after router acceptance", %{
    mesh_session_id: mesh_session_id
  } do
    original_state =
      swap_store_backend(MeshAgentMessageDeliveryPutFailBackend,
        fail_table: :mesh_handoff_ops,
        fail_reason: :delivery_bookkeeping_failed
      )

    on_exit(fn -> restore_store_backend(original_state) end)

    payload =
      capture_log_result(fn ->
        assert {:ok, payload} =
                 MeshAgentMessage.handle(
                   %{
                     "meshSessionId" => mesh_session_id,
                     "agentId" => "reviewer",
                     "prompt" => "Fail after router acceptance"
                   },
                   %{}
                 )

        payload
      end)

    assert_receive {:router_send_to_agent, "reviewer", "Fail after router acceptance", _opts}

    assert payload["deliveryAccepted"] == true
    assert payload["mailboxPersisted"] == true
    assert payload["blackboardPersisted"] == true

    assert {:ok, handoff} = LemonMesh.HandoffStore.get(payload["handoffId"])
    assert handoff.delivery_state == :blackboard_persisted
    assert handoff.delivery_sent_at_ms == nil
    assert handoff.message_id == payload["messageId"]
    assert handoff.handoff_entry_id == payload["handoffEntryId"]
  end

  test "reconciler restart repairs created handoffs without sending router delivery",
       %{
         mesh_session_id: mesh_session_id
       } do
    original_state =
      swap_store_backend(MeshAgentMessageTableFailBackend,
        fail_table: :mesh_peer_mailboxes,
        fail_reason: :mailbox_write_failed
      )

    details =
      capture_log_result(fn ->
        assert {:error, {:internal_error, "Failed to record mesh handoff", details}} =
                 MeshAgentMessage.handle(
                   %{
                     "meshSessionId" => mesh_session_id,
                     "agentId" => "reviewer",
                     "prompt" => "Reconcile me after restart"
                   },
                   %{}
                 )

        details
      end)

    assert details =~ "mailbox_persist_failed"
    refute_receive {:router_send_to_agent, "reviewer", "Reconcile me after restart", _opts}, 50

    assert [{handoff_id, _}] = LemonCore.Store.list(:mesh_handoff_ops)

    restore_store_backend(original_state)

    reconciler_pid = Process.whereis(LemonMesh.HandoffReconciler)
    Process.exit(reconciler_pid, :kill)

    restarted_reconciler = wait_for_pid(LemonMesh.HandoffReconciler, reconciler_pid)
    send(restarted_reconciler, :reconcile_tick)

    wait_for(fn ->
      with {:ok, handoff} <- LemonMesh.HandoffStore.get(handoff_id),
           {:ok, mailbox} <- LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer"),
           {:ok, entries} <- LemonMesh.list_blackboard_entries(mesh_session_id) do
        handoff.blackboard_persisted_at_ms != nil and length(mailbox) == 1 and
          length(entries) == 1
      else
        _ -> false
      end
    end)

    assert {:ok, handoff} = LemonMesh.HandoffStore.get(handoff_id)
    assert handoff.completed_at_ms == nil
    assert handoff.message_id != nil
    assert handoff.handoff_entry_id != nil
    assert handoff.delivery_state == :blackboard_persisted

    assert {:ok, [mailbox]} = LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")
    assert mailbox.message_id == handoff.message_id

    assert {:ok, [entry]} = LemonMesh.list_blackboard_entries(mesh_session_id)
    assert entry.entry_id == handoff.handoff_entry_id

    refute_receive {:router_send_to_agent, "reviewer", "Reconcile me after restart", _opts}, 50
  end

  test "forwards mesh_session_id through the real LemonRouter agent inbox path", %{
    mesh_session_id: mesh_session_id
  } do
    Application.put_env(:lemon_control_plane, :mesh_agent_message_router, LemonRouter)
    Application.put_env(:lemon_router, :agent_inbox_submitter, MeshAgentMessageSubmitterStub)
    Process.put(:mesh_agent_message_submitter_pid, self())

    assert {:ok, payload} =
             MeshAgentMessage.handle(
               %{
                 "meshSessionId" => mesh_session_id,
                 "agentId" => "reviewer",
                 "prompt" => "Route through real inbox path"
               },
               %{}
             )

    assert payload["runId"] == "run_submitter_stub"

    assert_receive {:submitted_request, request}, 500
    assert request.meta["mesh_session_id"] == mesh_session_id
    assert request.meta[:agent_inbox_message] == true
    assert request.meta[:agent_inbox_followup] == true
  end

  test "mesh.agent.message completes handoff after runtime applies the mailbox prompt", %{
    mesh_session_id: mesh_session_id
  } do
    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("runtime complete")),
        mesh_session_id: mesh_session_id,
        agent_id: "reviewer",
        mesh_mailbox_poll_interval_ms: 10
      )

    assert {:ok, payload} =
             MeshAgentMessage.handle(
               %{
                 "meshSessionId" => mesh_session_id,
                 "agentId" => "reviewer",
                 "prompt" => "Drive this handoff through runtime apply"
               },
               %{}
             )

    wait_for_session_run(session, 2)

    wait_for(fn ->
      with {:ok, handoff} <- LemonMesh.HandoffStore.get(payload["handoffId"]) do
        handoff.delivery_state == :completed and
          is_integer(handoff.runtime_accepted_at_ms) and
          is_integer(handoff.runtime_applied_at_ms) and
          is_integer(handoff.completed_at_ms)
      else
        _ -> false
      end
    end)

    assert {:ok, handoff} = LemonMesh.HandoffStore.get(payload["handoffId"])
    assert handoff.delivery_state == :completed
    assert handoff.runtime_accepted_at_ms != nil
    assert handoff.runtime_applied_at_ms != nil
    assert handoff.completed_at_ms != nil
    assert handoff.message_id == payload["messageId"]
    assert handoff.handoff_entry_id == payload["handoffEntryId"]
  end

  defp swap_store_backend(backend, opts) do
    original_state = :sys.get_state(CoreStore)

    backend_state = %{
      delegate: original_state.backend,
      delegate_state: original_state.backend_state,
      fail_table: Keyword.fetch!(opts, :fail_table),
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

  defp wait_for(fun, attempts \\ 50)

  defp wait_for(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_for(fun, attempts - 1)
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition not met in time")

  defp wait_for_pid(name, previous_pid, attempts \\ 50)

  defp wait_for_pid(name, previous_pid, attempts) when attempts > 0 do
    case Process.whereis(name) do
      nil ->
        Process.sleep(10)
        wait_for_pid(name, previous_pid, attempts - 1)

      pid when pid != previous_pid ->
        pid

      _same_pid ->
        Process.sleep(10)
        wait_for_pid(name, previous_pid, attempts - 1)
    end
  end

  defp wait_for_pid(_name, _previous_pid, 0), do: flunk("pid not restarted in time")

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: "Mock Model",
      provider: "mock-provider",
      api: "mock-api",
      base_url: "mock://",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 200_000,
      max_tokens: 8_192
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{text: text}],
      provider: "mock-provider",
      model: "mock-model-1",
      api: "mock-api",
      usage: %Usage{input: 1, output: 1, total_tokens: 2, cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _opts ->
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(stream, {:start, response})
        Ai.EventStream.push(stream, {:text_start, 0, response})

        Enum.each(response.content, fn
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_delta, 0, text, response})

          _other ->
            :ok
        end)

        Ai.EventStream.push(stream, {:text_end, 0, response})
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp wait_for_session_run(session, min_messages) do
    wait_for(fn ->
      state = Session.get_state(session)
      not state.is_streaming and length(Session.get_messages(session)) >= min_messages
    end)
  end
end
