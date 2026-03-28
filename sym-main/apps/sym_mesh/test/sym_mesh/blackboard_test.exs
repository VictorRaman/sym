defmodule LemonMesh.BlackboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{BlackboardEntry, Op, OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.{Projector, Watermark}

  defmodule BlackboardSessionMetadataFailBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(%{fail_reason: fail_reason}, :mesh_sessions, _key, _value), do: {:error, fail_reason}

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
    OpLog.reset()
    Watermark.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "append_blackboard_entry/2 stores and lists entries for a running session" do
    {:ok, pid} = LemonMesh.start_session(goal: "Shared memory test")
    session_id = LemonMesh.session_id(pid)

    {:ok, entry} =
      LemonMesh.append_blackboard_entry(session_id, %{
        kind: "fact",
        author: "planner",
        scope: "facts",
        body: %{"summary" => "Found the scheduling boundary"},
        artifact_refs: ["docs/architecture.md"]
      })

    assert entry.session_id == session_id
    assert entry.kind == "fact"
    assert entry.author == "planner"

    {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)

    assert length(entries) == 1
    assert hd(entries).entry_id == entry.entry_id
    assert hd(entries).body == %{"summary" => "Found the scheduling boundary"}

    [op] = OpLog.list(entity_type: "blackboard", entity_id: session_id)
    assert op.op_type == "entry_appended"
    assert op.entity_id == session_id
    assert op.payload[:entry_id] == entry.entry_id or op.payload["entry_id"] == entry.entry_id
    assert Watermark.local()[op.origin_node_id] >= op.causal_clock[op.origin_node_id]
  end

  test "blackboard entries remain available after the session stops" do
    {:ok, pid} = LemonMesh.start_session(goal: "Persistence test")
    session_id = LemonMesh.session_id(pid)

    {:ok, _entry} =
      LemonMesh.append_blackboard_entry(session_id, %{
        kind: "decision",
        author: "reviewer",
        scope: "decisions",
        body: %{"decision" => "Use explicit shared files only"}
      })

    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)

    assert length(entries) == 1
    assert hd(entries).kind == "decision"
    assert hd(entries).body == %{"decision" => "Use explicit shared files only"}
  end

  test "append_blackboard_entry/2 writes through to a stopped persisted session" do
    {:ok, pid} = LemonMesh.start_session(goal: "Stopped session write-through")
    session_id = LemonMesh.session_id(pid)

    {:ok, _entry} =
      LemonMesh.append_blackboard_entry(session_id, %{
        kind: "fact",
        author: "planner",
        scope: "facts",
        body: %{"summary" => "initial fact"}
      })

    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    {:ok, appended} =
      LemonMesh.append_blackboard_entry(session_id, %{
        kind: "handoff",
        author: "control_plane",
        scope: "mesh",
        body: %{"summary" => "persisted write"}
      })

    assert appended.session_id == session_id
    assert appended.kind == "handoff"

    {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)

    assert length(entries) == 2
    assert Enum.at(entries, 1).entry_id == appended.entry_id

    snapshot = LemonMesh.get_session!(session_id)
    assert snapshot.status == :stopped
    assert snapshot.blackboard_size == 2
  end

  test "append_blackboard_entry/2 still succeeds when session metadata refresh fails" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "Stopped session metadata failure append")
      session_id = LemonMesh.session_id(pid)

      assert :ok = SessionSupervisor.stop_session(pid)
      Process.sleep(20)

      original_state =
        swap_store_backend(
          BlackboardSessionMetadataFailBackend,
          fail_reason: :metadata_write_failed
        )

      on_exit(fn -> restore_store_backend(original_state) end)

      assert {:ok, appended} =
               LemonMesh.append_blackboard_entry(session_id, %{
                 kind: "handoff",
                 author: "control_plane",
                 scope: "mesh",
                 body: %{"summary" => "persist even if metadata refresh fails"}
               })

      assert appended.session_id == session_id

      assert {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)
      assert Enum.any?(entries, &(&1.entry_id == appended.entry_id))
    end)
  end

  test "active sessions read blackboard entries projected from authoritative ops" do
    {:ok, pid} = LemonMesh.start_session(goal: "Live blackboard projection")
    session_id = LemonMesh.session_id(pid)

    {:ok, local_entry} =
      LemonMesh.append_blackboard_entry(session_id, %{
        kind: "fact",
        author: "planner",
        scope: "facts",
        body: %{"summary" => "local"}
      })

    remote_entry =
      BlackboardEntry.new(session_id, %{
        entry_id: "bb_remote_projection_1",
        kind: "fact",
        author: "peer-a",
        scope: "facts",
        body: %{"summary" => "remote"},
        inserted_at_ms: local_entry.inserted_at_ms + 10
      })

    assert {:ok, _messages} =
             Projector.project(
               Op.new(%{
                 op_id: "bb_remote_projection_1:entry_appended",
                 origin_node_id: "peer-a@host",
                 entity_type: "blackboard",
                 entity_id: session_id,
                 op_type: "entry_appended",
                 causal_clock: %{"peer-a@host" => 1},
                 payload: BlackboardEntry.to_map(remote_entry)
               })
             )

    assert {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)
    assert Enum.map(entries, & &1.entry_id) == [local_entry.entry_id, remote_entry.entry_id]
    assert Enum.at(entries, 1).body == %{"summary" => "remote"}
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
end
