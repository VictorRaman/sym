defmodule ControlPlaneCodexSmokeScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/control_plane_codex_smoke.mjs")

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "control_plane_codex_smoke_script_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "--check-only fails fast when Lemon config is missing", %{tmp_dir: tmp_dir} do
    fake_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(fake_home)

    {output, status} =
      System.cmd(
        node_bin!(),
        [@script, "--check-only"],
        cd: @repo_root,
        env: [{"HOME", fake_home}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Missing Lemon config"
    assert output =~ Path.join(fake_home, ".lemon/config.toml")
  end

  test "--check-only passes with a minimal Codex smoke config and a fake codex binary", %{
    tmp_dir: tmp_dir
  } do
    fake_home = Path.join(tmp_dir, "home")
    fake_bin = Path.join(tmp_dir, "bin")
    fake_codex = Path.join(fake_bin, "fake-codex")

    File.mkdir_p!(Path.join(fake_home, ".lemon"))
    File.mkdir_p!(fake_bin)

    File.write!(
      Path.join(fake_home, ".lemon/config.toml"),
      """
      [runtime.cli.codex]
      extra_args = ["-c", "notify=[]"]

      [gateway]
      default_engine = "lemon"
      """
    )

    File.write!(
      fake_codex,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      if [[ "${1:-}" == "--version" ]]; then
        printf 'codex-cli test-build\\n'
        exit 0
      fi
      printf 'unexpected args: %s\\n' "$*" >&2
      exit 1
      """
    )

    File.chmod!(fake_codex, 0o755)

    {output, status} =
      System.cmd(
        node_bin!(),
        [@script, "--check-only", "--codex-bin", fake_codex],
        cd: @repo_root,
        env: [{"HOME", fake_home}],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "CODEX_SMOKE_PREFLIGHT_OK"
    assert output =~ Path.join(fake_home, ".lemon/config.toml")
    assert output =~ fake_codex
  end

  test "default session keys are unique per invocation" do
    module_url = "file://" <> @script

    script = """
    import { buildDefaultOptions } from #{inspect(module_url)};

    const first = buildDefaultOptions();
    const second = buildDefaultOptions();

    console.log(JSON.stringify({
      firstA: first.sessionA,
      firstB: first.sessionB,
      secondA: second.sessionA,
      secondB: second.sessionB,
      sameWithinFirst: first.sessionA === first.sessionB,
      sameAcrossCalls: first.sessionA === second.sessionA || first.sessionB === second.sessionB
    }));
    """

    {output, status} =
      System.cmd(
        node_bin!(),
        ["--input-type=module", "--eval", script],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0

    decoded = Jason.decode!(output)
    assert decoded["sameWithinFirst"] == false
    assert decoded["sameAcrossCalls"] == false
    assert String.starts_with?(decoded["firstA"], "agent:default:codex-op-a-")
    assert String.starts_with?(decoded["firstB"], "agent:default:codex-op-b-")
  end

  defp node_bin! do
    System.find_executable("node") ||
      raise "node executable is required to test scripts/control_plane_codex_smoke.mjs"
  end
end
