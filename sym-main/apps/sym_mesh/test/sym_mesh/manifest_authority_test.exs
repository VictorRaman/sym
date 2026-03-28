defmodule LemonMesh.ManifestAuthorityTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store, as: CoreStore
  alias LemonMesh.{OpLog, SessionSupervisor, Store}
  alias LemonMesh.Replication.{Projector, Watermark}

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

  test "manifest writes emit authoritative ops and get_session/get_manifest/list_sessions rebuild from them" do
    {:ok, pid} =
      LemonMesh.start_session(
        goal: "Manifest authority",
        roles: ["planner", "reviewer"],
        memory_scopes: ["facts"]
      )

    session_id = LemonMesh.session_id(pid)

    assert :ok = SessionSupervisor.stop_session(pid)
    wait_for(fn -> LemonMesh.session_pid(session_id) == :error end)

    ops = OpLog.list(entity_type: "manifest", entity_id: session_id)
    assert Enum.any?(ops, &(&1.op_type == "manifest_upserted"))

    assert :ok = CoreStore.delete(:mesh_sessions, session_id)
    assert CoreStore.get(:mesh_sessions, session_id) == nil

    assert {:error, :not_found} = LemonMesh.get_session(session_id)

    assert {:ok, rebuilt} = Projector.rebuild_entity("manifest", session_id)
    assert rebuilt.session_id == session_id
    assert rebuilt.status == :stopped

    assert {:ok, snapshot} = LemonMesh.get_session(session_id)
    assert snapshot.session_id == session_id
    assert snapshot.status == :stopped
    assert snapshot.goal == "Manifest authority"

    assert {:ok, manifest} = LemonMesh.get_manifest(session_id)
    assert manifest.session_id == session_id
    assert manifest.roles == ["planner", "reviewer"]

    sessions = LemonMesh.list_sessions()
    assert Enum.any?(sessions, &(&1.session_id == session_id and &1.status == :stopped))
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
end
