defmodule LemonMesh.SessionSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonMesh.{SessionRegistry, SessionSupervisor, Store}

  setup do
    Application.ensure_all_started(:lemon_mesh)
    Store.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "starts a mesh session and exposes its snapshot through the facade" do
    {:ok, pid} =
      LemonMesh.start_session(
        goal: "Coordinate a coding task",
        roles: ["planner", "implementer", "reviewer"],
        memory_scopes: ["facts", "decisions"]
      )

    assert Process.alive?(pid)

    snapshot = LemonMesh.get_session!(LemonMesh.session_id(pid))

    assert snapshot.session_id == LemonMesh.session_id(pid)
    assert snapshot.goal == "Coordinate a coding task"
    assert snapshot.roles == ["planner", "implementer", "reviewer"]
    assert snapshot.memory_scopes == ["facts", "decisions"]
    assert snapshot.status == :active
    assert snapshot.blackboard_size == 0
  end

  test "list_sessions/0 returns active mesh sessions" do
    {:ok, pid1} = LemonMesh.start_session(goal: "Task 1")
    {:ok, pid2} = LemonMesh.start_session(goal: "Task 2")

    sessions = LemonMesh.list_sessions()
    ids = Enum.map(sessions, & &1.session_id)

    assert LemonMesh.session_id(pid1) in ids
    assert LemonMesh.session_id(pid2) in ids
  end

  test "get_manifest/1 returns the typed manifest for a session" do
    {:ok, pid} =
      LemonMesh.start_session(
        goal: "Manifest access test",
        roles: ["planner"],
        delivery_semantics: "at_least_once"
      )

    {:ok, manifest} = LemonMesh.get_manifest(LemonMesh.session_id(pid))

    assert manifest.session_id == LemonMesh.session_id(pid)
    assert manifest.goal == "Manifest access test"
    assert manifest.roles == ["planner"]
    assert manifest.delivery_semantics == "at_least_once"
  end

  test "normal stop persists stopped status" do
    {:ok, pid} = LemonMesh.start_session(goal: "Stopped state test")
    session_id = LemonMesh.session_id(pid)

    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    snapshot = LemonMesh.get_session!(session_id)
    assert snapshot.status == :stopped
  end

  test "abnormal exit restarts the session with the same identity and persisted blackboard" do
    capture_log(fn ->
      {:ok, pid} = LemonMesh.start_session(goal: "Crash recovery test")
      session_id = LemonMesh.session_id(pid)

      {:ok, entry} =
        LemonMesh.append_blackboard_entry(session_id, %{
          kind: "fact",
          author: "planner",
          body: %{"summary" => "survives restart"}
        })

      :ok = GenServer.stop(pid, :boom)

      restarted_pid = wait_for_restarted_session(session_id, pid)
      assert is_pid(restarted_pid)
      assert restarted_pid != pid

      snapshot = LemonMesh.get_session!(session_id)
      assert snapshot.session_id == session_id
      assert snapshot.status == :active
      assert snapshot.blackboard_size == 1

      {:ok, entries} = LemonMesh.list_blackboard_entries(session_id)
      assert [restored] = entries
      assert restored.entry_id == entry.entry_id
      assert restored.body == %{"summary" => "survives restart"}
    end)
  end

  defp wait_for_restarted_session(session_id, old_pid, attempts \\ 20)

  defp wait_for_restarted_session(session_id, old_pid, attempts) when attempts > 0 do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} when pid != old_pid and is_pid(pid) ->
        pid

      _ ->
        Process.sleep(25)
        wait_for_restarted_session(session_id, old_pid, attempts - 1)
    end
  end

  defp wait_for_restarted_session(_session_id, _old_pid, 0), do: nil
end
