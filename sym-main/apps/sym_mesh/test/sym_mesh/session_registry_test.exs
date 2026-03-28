defmodule LemonMesh.SessionRegistryTest do
  use ExUnit.Case, async: false

  alias LemonMesh.SessionRegistry

  setup do
    Application.ensure_all_started(:lemon_mesh)

    unless Process.whereis(SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry})
    end

    :ok
  end

  test "via/1 returns a registry via tuple" do
    session_id = "mesh_session_#{System.unique_integer([:positive])}"

    assert {:via, Registry, {LemonMesh.SessionRegistry, ^session_id}} =
             SessionRegistry.via(session_id)
  end

  test "lookup/1 returns :error for missing session" do
    assert :error = SessionRegistry.lookup("missing-session")
  end

  test "list_ids/0 includes registered session ids" do
    session_id = "mesh_session_#{System.unique_integer([:positive])}"
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: SessionRegistry.via(session_id))

    assert session_id in SessionRegistry.list_ids()

    Agent.stop(pid)
  end
end

