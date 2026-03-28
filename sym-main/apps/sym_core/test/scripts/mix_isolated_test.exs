defmodule MixIsolatedScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/mix_isolated.sh")

  test "auto-selects a newer local elixir-install toolchain when PATH is too old" do
    tmp_dir = Path.join(System.tmp_dir!(), "mix_isolated_script_#{System.unique_integer([:positive])}")
    fake_home = Path.join(tmp_dir, "home")
    repo_cwd = Path.join(tmp_dir, "repo")
    old_bin = Path.join(tmp_dir, "old/bin")
    new_bin = Path.join(fake_home, ".elixir-install/installs/elixir/1.19.5-otp-27/bin")
    otp_bin = Path.join(fake_home, ".elixir-install/installs/otp/27.1/bin")

    File.mkdir_p!(repo_cwd)
    File.mkdir_p!(old_bin)
    File.mkdir_p!(new_bin)
    File.mkdir_p!(otp_bin)

    write_fake_elixir(Path.join(old_bin, "elixir"), "1.17.3")
    write_fake_mix(Path.join(old_bin, "mix"), "old")
    write_fake_elixir(Path.join(new_bin, "elixir"), "1.19.5")
    write_fake_mix(Path.join(new_bin, "mix"), "new")
    write_fake_erl(Path.join(otp_bin, "erl"))

    env = [
      {"HOME", fake_home},
      {"PATH", old_bin <> ":" <> System.get_env("PATH", "")}
    ]

    {output, 0} =
      System.cmd(
        @script,
        ["--cwd", repo_cwd, "--", "--version"],
        cd: @repo_root,
        env: env,
        stderr_to_stdout: true
      )

    assert output =~ "mix_isolated: auto-selected toolchain elixir="
    assert output =~ Path.join(new_bin, "elixir")
    assert output =~ "fake mix (new) args: --version"
    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)
  end

  defp write_fake_elixir(path, version) do
    File.write!(
      path,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      if [[ "${1:-}" == "-e" ]]; then
        if [[ $# -ge 3 ]]; then
          if [[ "#{version}" == "1.19.5" ]]; then
            printf 'ok'
          else
            printf 'too_old'
          fi
        else
          printf '#{version}'
        fi
      elif [[ "${1:-}" == "--version" ]]; then
        printf 'Elixir #{version}\n'
      else
        printf '#{version}'
      fi
      """
    )

    File.chmod!(path, 0o755)
  end

  defp write_fake_mix(path, label) do
    File.write!(
      path,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      printf 'fake mix (#{label}) args: %s\n' "$*"
      """
    )

    File.chmod!(path, 0o755)
  end

  defp write_fake_erl(path) do
    File.write!(
      path,
      """
      #!/usr/bin/env bash
      exit 0
      """
    )

    File.chmod!(path, 0o755)
  end
end
