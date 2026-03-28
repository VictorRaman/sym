defmodule LemonMesh.Config do
  @moduledoc false

  alias LemonCore.Config, as: CoreConfig

  @defaults %{
    trusted_peers: [],
    replication_poll_interval_ms: 1_000,
    replication_batch_limit: 200,
    snapshot_scope: "mesh_state",
    lease_ttl_ms: 60_000
  }

  @spec load(String.t() | nil) :: map()
  def load(cwd \\ nil) do
    global = CoreConfig.load_file(CoreConfig.global_path())

    project =
      cwd
      |> normalize_cwd()
      |> CoreConfig.project_path()
      |> CoreConfig.load_file()

    mesh =
      global
      |> Map.get("mesh", %{})
      |> deep_merge(Map.get(project, "mesh", %{}))

    %{
      trusted_peers:
        env_list("LEMON_MESH_TRUSTED_PEERS") ||
          normalize_string_list(Map.get(mesh, "trusted_peers", @defaults.trusted_peers)),
      replication_poll_interval_ms:
        env_int(
          "LEMON_MESH_REPLICATION_POLL_INTERVAL_MS",
          Map.get(mesh, "replication_poll_interval_ms", @defaults.replication_poll_interval_ms)
        ),
      replication_batch_limit:
        env_int(
          "LEMON_MESH_REPLICATION_BATCH_LIMIT",
          Map.get(mesh, "replication_batch_limit", @defaults.replication_batch_limit)
        ),
      snapshot_scope:
        env_string("LEMON_MESH_SNAPSHOT_SCOPE") ||
          normalize_snapshot_scope(Map.get(mesh, "snapshot_scope", @defaults.snapshot_scope)),
      lease_ttl_ms:
        env_int("LEMON_MESH_LEASE_TTL_MS", Map.get(mesh, "lease_ttl_ms", @defaults.lease_ttl_ms))
    }
  end

  defp normalize_cwd(nil), do: File.cwd!()
  defp normalize_cwd(""), do: File.cwd!()
  defp normalize_cwd(cwd), do: cwd

  defp env_list(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        normalize_positive_int(default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> normalize_positive_int(parsed)
          _ -> normalize_positive_int(default)
        end
    end
  end

  defp env_string(name) do
    case System.get_env(name) do
      nil -> nil
      value -> normalize_snapshot_scope(value)
    end
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_value), do: []

  defp normalize_positive_int(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value), do: 1_000

  defp normalize_snapshot_scope(value) when is_binary(value) and value != "", do: value
  defp normalize_snapshot_scope(_value), do: @defaults.snapshot_scope

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
