defmodule LemonMesh.Replication.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonMesh.Config

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "lemon_mesh_config_test_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    project = Path.join(root, "project")

    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))

    original_home = System.get_env("HOME")
    original_env = System.get_env("LEMON_MESH_TRUSTED_PEERS")

    System.put_env("HOME", home)
    System.delete_env("LEMON_MESH_TRUSTED_PEERS")

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_env do
        System.put_env("LEMON_MESH_TRUSTED_PEERS", original_env)
      else
        System.delete_env("LEMON_MESH_TRUSTED_PEERS")
      end

      File.rm_rf!(root)
    end)

    %{home: home, project: project}
  end

  test "project mesh settings override global and env overrides both", %{
    home: home,
    project: project
  } do
    File.write!(
      Path.join([home, ".lemon", "config.toml"]),
      """
      [mesh]
      trusted_peers = ["global-a@host", "global-b@host"]
      replication_poll_interval_ms = 5000
      replication_batch_limit = 50
      snapshot_scope = "mesh_state"
      lease_ttl_ms = 60000
      """
    )

    File.write!(
      Path.join([project, ".lemon", "config.toml"]),
      """
      [mesh]
      trusted_peers = ["project-a@host"]
      replication_poll_interval_ms = 250
      replication_batch_limit = 20
      """
    )

    assert %{
             trusted_peers: ["project-a@host"],
             replication_poll_interval_ms: 250,
             replication_batch_limit: 20,
             snapshot_scope: "mesh_state",
             lease_ttl_ms: 60_000
           } = Config.load(project)

    System.put_env("LEMON_MESH_TRUSTED_PEERS", "env-a@host,env-b@host")

    assert %{
             trusted_peers: ["env-a@host", "env-b@host"],
             replication_poll_interval_ms: 250
           } = Config.load(project)
  end
end
