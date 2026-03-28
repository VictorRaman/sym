defmodule LemonGateway.TestArtifactRootTest do
  use ExUnit.Case, async: true

  test "isolates lock dir under shared test artifact root" do
    artifact_root = System.get_env("LEMON_TEST_ARTIFACT_ROOT")
    lock_dir = System.get_env("LEMON_LOCK_DIR")

    assert is_binary(artifact_root)
    assert artifact_root != ""
    assert is_binary(lock_dir)
    assert String.starts_with?(lock_dir, artifact_root)
  end
end
