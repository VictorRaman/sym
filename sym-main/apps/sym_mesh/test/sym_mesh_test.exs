defmodule LemonMeshTest do
  use ExUnit.Case, async: false

  alias LemonMesh.{SessionSupervisor, Store}

  setup do
    Application.ensure_all_started(:lemon_mesh)
    Store.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "get_session/1 returns {:error, :not_found} for missing sessions" do
    assert {:error, :not_found} = LemonMesh.get_session("missing-session")
  end
end
