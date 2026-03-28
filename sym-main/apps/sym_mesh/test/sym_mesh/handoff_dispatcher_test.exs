defmodule LemonMesh.HandoffDispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{HandoffDispatcher, HandoffStore, OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.Watermark

  defmodule HandoffDispatcherTableFailBackend do
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

  defmodule HandoffDispatcherExistingRecordPutFailBackend do
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

  defmodule HandoffDispatcherDeliveryPutFailBackend do
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

    Store.reset()
    HandoffStore.reset()
    OpLog.reset()
    Watermark.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "direct reconcile repairs mailbox persistence without re-sending router delivery" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "handoff mailbox reconcile")
      mesh_session_id = LemonMesh.session_id(pid)

      original_state =
        swap_store_backend(HandoffDispatcherTableFailBackend,
          fail_table: :mesh_peer_mailboxes,
          fail_reason: :mailbox_write_failed
        )

      on_exit(fn -> restore_store_backend(original_state) end)

      assert {:error, {:mailbox_persist_failed, :mailbox_write_failed}} =
               HandoffDispatcher.dispatch(%{
                 mesh_session_id: mesh_session_id,
                 agent_id: "reviewer",
                 prompt: "Repair mailbox bookkeeping",
                 queue_mode: "followup",
                 send_fn: send_stub(self())
               })

      refute_receive {:router_send_to_agent, "reviewer", "Repair mailbox bookkeeping", _opts}, 50

      restore_store_backend(original_state)
      wait_for_peer_mailbox_ops(mesh_session_id)

      assert [{handoff_id, _record}] = table_entries(mesh_session_id)
      assert {:ok, handoff} = HandoffStore.get(handoff_id)
      assert handoff.delivery_state == :created
      assert {:ok, updated} = HandoffDispatcher.reconcile(handoff)

      refute_receive {:router_send_to_agent, "reviewer", "Repair mailbox bookkeeping", _opts}, 50
      assert updated.completed_at_ms == nil
      assert updated.message_id != nil
      assert updated.handoff_entry_id != nil
      assert updated.delivery_state == :blackboard_persisted

      assert {:ok, [mailbox]} =
               LemonMesh.list_peer_messages(mesh_session_id, to_agent: "reviewer")

      assert mailbox.message_id == updated.message_id

      assert {:ok, [entry]} = LemonMesh.list_blackboard_entries(mesh_session_id)
      assert entry.entry_id == updated.handoff_entry_id
    end)
  end

  test "direct reconcile repairs blackboard persistence without re-sending router delivery" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "handoff blackboard reconcile")
      mesh_session_id = LemonMesh.session_id(pid)

      original_state =
        swap_store_backend(HandoffDispatcherTableFailBackend,
          fail_table: :mesh_blackboards,
          fail_reason: :blackboard_write_failed
        )

      on_exit(fn -> restore_store_backend(original_state) end)

      assert {:error, {:blackboard_persist_failed, :blackboard_write_failed}} =
               HandoffDispatcher.dispatch(%{
                 mesh_session_id: mesh_session_id,
                 agent_id: "reviewer",
                 prompt: "Repair blackboard bookkeeping",
                 queue_mode: "followup",
                 send_fn: send_stub(self())
               })

      refute_receive {:router_send_to_agent, "reviewer", "Repair blackboard bookkeeping", _opts}, 50

      restore_store_backend(original_state)

      assert [{handoff_id, _record}] = table_entries(mesh_session_id)
      assert {:ok, handoff} = HandoffStore.get(handoff_id)
      assert handoff.delivery_state == :mailbox_persisted
      assert {:ok, updated} = HandoffDispatcher.reconcile(handoff)

      refute_receive {:router_send_to_agent, "reviewer", "Repair blackboard bookkeeping", _opts}, 50
      assert updated.completed_at_ms == nil
      assert updated.message_id != nil
      assert updated.handoff_entry_id != nil
      assert updated.delivery_state == :blackboard_persisted

      assert {:ok, [entry]} = LemonMesh.list_blackboard_entries(mesh_session_id)
      assert entry.entry_id == updated.handoff_entry_id
    end)
  end

  test "delivery bookkeeping failures do not erase durable handoff state" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "handoff delivery bookkeeping reconcile")
      mesh_session_id = LemonMesh.session_id(pid)

      original_state =
        swap_store_backend(HandoffDispatcherDeliveryPutFailBackend,
          fail_table: :mesh_handoff_ops,
          fail_reason: :delivery_bookkeeping_failed
        )

      on_exit(fn -> restore_store_backend(original_state) end)

      assert {:ok, result} =
               HandoffDispatcher.dispatch(%{
                 mesh_session_id: mesh_session_id,
                 agent_id: "reviewer",
                 prompt: "Recover delivery bookkeeping",
                 queue_mode: "followup",
                 send_fn: send_stub(self())
               })

      assert_receive {:router_send_to_agent, "reviewer", "Recover delivery bookkeeping", _opts}

      assert {:ok, handoff} = HandoffStore.get(result.handoff_id)
      assert handoff.delivery_state == :blackboard_persisted
      assert handoff.delivery_sent_at_ms == nil
      assert handoff.message_id == result.message_id
      assert handoff.handoff_entry_id == result.handoff_entry_id
      assert HandoffStore.list_reconcilable() == []

      refute_receive {:router_send_to_agent, "reviewer", "Recover delivery bookkeeping", _opts},
                     50
    end)
  end

  test "router send failure still returns a durable handoff result" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "handoff durable before router")
      mesh_session_id = LemonMesh.session_id(pid)

      assert {:ok, result} =
               HandoffDispatcher.dispatch(%{
                 mesh_session_id: mesh_session_id,
                 agent_id: "reviewer",
                 prompt: "Persist before router fast path",
                 queue_mode: "followup",
                 send_fn: fn _agent_id, _prompt, _opts -> {:error, :router_unavailable} end
               })

      assert result.delivery_accepted == false
      assert result.mailbox_persisted == true
      assert result.blackboard_persisted == true
      assert is_binary(result.message_id)
      assert is_binary(result.handoff_entry_id)

      assert {:ok, handoff} = HandoffStore.get(result.handoff_id)
      assert handoff.delivery_state == :blackboard_persisted
      assert handoff.message_id == result.message_id
      assert handoff.handoff_entry_id == result.handoff_entry_id
      assert handoff.delivery_sent_at_ms == nil
    end)
  end

  test "reconcile failure logs handoff correlation fields" do
    {mesh_session_id, handoff} =
      capture_log(fn ->
        {:ok, pid} = LemonMesh.start_session(goal: "handoff reconcile logging")
        mesh_session_id = LemonMesh.session_id(pid)

        original_state =
          swap_store_backend(HandoffDispatcherTableFailBackend,
            fail_table: :mesh_blackboards,
            fail_reason: :blackboard_write_failed
          )

        on_exit(fn -> restore_store_backend(original_state) end)

        assert {:error, {:blackboard_persist_failed, :blackboard_write_failed}} =
                 HandoffDispatcher.dispatch(%{
                   mesh_session_id: mesh_session_id,
                   agent_id: "reviewer",
                   prompt: "Log correlation fields",
                   queue_mode: "followup",
                   send_fn: send_stub(self())
                 })

        refute_receive {:router_send_to_agent, "reviewer", "Log correlation fields", _opts}, 50

        assert [{handoff_id, _record}] = table_entries(mesh_session_id)
        assert {:ok, handoff} = HandoffStore.get(handoff_id)
        send(self(), {:handoff_logging_context, mesh_session_id, handoff})
      end)
      |> then(fn _log ->
        receive do
          {:handoff_logging_context, mesh_session_id, handoff} -> {mesh_session_id, handoff}
        end
      end)

    log =
      capture_log(fn ->
        assert {:error, :blackboard_write_failed} = HandoffDispatcher.reconcile(handoff)

        send(LemonMesh.HandoffReconciler, :reconcile_tick)
        Process.sleep(50)
      end)

    assert log =~ "handoff_id=#{handoff.handoff_id}"
    assert log =~ "mesh_session_id=#{mesh_session_id}"
    assert log =~ "message_id=#{handoff.message_id}"
  end

  defp send_stub(owner) do
    fn agent_id, prompt, opts ->
      send(owner, {:router_send_to_agent, agent_id, prompt, opts})

      {:ok,
       %{
         run_id: "run_stub_1",
         session_key: "agent:reviewer:main",
         selector: :latest,
         fanout_count: 0
       }}
    end
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

  defp wait_for_peer_mailbox_ops(mesh_session_id, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_peer_mailbox_ops(mesh_session_id, deadline)
  end

  defp do_wait_for_peer_mailbox_ops(mesh_session_id, deadline_ms) do
    has_ops? =
      OpLog.list(entity_type: "peer_mailbox")
      |> Enum.any?(fn op ->
        payload = Map.get(op, :payload, %{})
        Map.get(payload, :session_id) == mesh_session_id
      end)

    cond do
      has_ops? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for peer_mailbox op log entries")

      true ->
        Process.sleep(20)
        do_wait_for_peer_mailbox_ops(mesh_session_id, deadline_ms)
    end
  end

  defp table_entries(mesh_session_id) do
    LemonCore.Store.list(:mesh_handoff_ops)
    |> Enum.filter(fn {_handoff_id, record} ->
      Map.get(record, :mesh_session_id) == mesh_session_id
    end)
  end
end
