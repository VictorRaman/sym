defmodule CodingAgent.TestArtifactRootTest do
  use ExUnit.Case, async: true

  test "isolates home and agent dir under shared test artifact root" do
    artifact_root = System.get_env("LEMON_TEST_ARTIFACT_ROOT")
    home = System.get_env("HOME")
    resolved_home = resolve_realpath(home)
    resolved_agent_dir = resolve_realpath(CodingAgent.Config.agent_dir())

    assert is_binary(artifact_root)
    assert artifact_root != ""
    assert is_binary(home)

    case resolved_home do
      {:ok, real_home} ->
        assert String.starts_with?(real_home, artifact_root)

      {:error, _} ->
        assert String.starts_with?(home, artifact_root)
    end

    case resolved_agent_dir do
      {:ok, real_agent_dir} ->
        assert String.starts_with?(real_agent_dir, artifact_root)

      {:error, _} ->
        assert String.starts_with?(CodingAgent.Config.agent_dir(), artifact_root)
    end
  end

  defp resolve_realpath(path) when is_binary(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} -> {:ok, List.to_string(resolved)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_realpath(_), do: {:error, :enoent}
end
