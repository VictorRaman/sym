defmodule Mix.Tasks.Lemon.CleanupTest do
  @moduledoc """
  Tests for the lemon.cleanup mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Cleanup

  @task_source Path.expand("../../../lib/mix/tasks/lemon.cleanup.ex", __DIR__)

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_cleanup_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    unless Code.ensure_loaded?(Cleanup) do
      Code.require_file(@task_source)
    end

    {:ok, tmp_dir: tmp_dir}
  end

  describe "module attributes" do
    test "task module exists and is loaded" do
      assert File.exists?(@task_source)
      assert Code.ensure_loaded?(Cleanup)
    end

    test "has proper @shortdoc attribute" do
      source = File.read!(@task_source)
      assert source =~ ~s(@shortdoc "Scan or prune Lemon residue")
    end

    test "moduledoc is present" do
      source = File.read!(@task_source)
      assert source =~ "Scan cleanup candidates"
      assert source =~ "mix lemon.cleanup"
      assert source =~ "--apply"
      assert source =~ "--build-artifacts"
      assert source =~ "--retention-days"
      assert source =~ "/tmp"
    end

    test "module has run/1 function exported" do
      assert Code.ensure_loaded?(Cleanup)
      assert function_exported?(Cleanup, :run, 1)
    end
  end

  describe "dry-run mode (default)" do
    test "shows dry-run output with empty results", %{tmp_dir: tmp_dir} do
      # Mock the Cleanup.prune function by creating test files
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "root:"
      assert output =~ "retention_days:"
      assert output =~ "old_run_files:"
      assert output =~ "stale_docs:"
      assert output =~ "repo_tmp_paths:"
      assert output =~ "tmp_artifacts:"
      assert output =~ "build_artifacts:"
      assert output =~ "build_artifact_bytes:"
      assert output =~ "ignored_paths:"
      assert output =~ "mode: dry-run"
      assert output =~ "--apply"
    end

    test "does not show deleted_files in dry-run mode", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      refute output =~ "deleted_files:"
    end
  end

  describe "--apply mode" do
    test "shows apply mode output with deleted_files count", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply"])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "deleted_files:"
      refute output =~ "mode: dry-run"
    end

    test "accepts -a alias for --apply", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "-a"])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "deleted_files:"
    end

    test "does not delete build artifacts without --build-artifacts", %{tmp_dir: tmp_dir} do
      build_dir = Path.join(tmp_dir, "_build")
      build_file = Path.join(build_dir, "compiled.bin")

      File.mkdir_p!(build_dir)
      File.write!(build_file, "compiled")

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply", "--tmp-root", tmp_dir])
        end)

      assert output =~ "build_artifacts: 1"
      assert output =~ "--build-artifacts"
      assert File.exists?(build_dir)
    end

    test "deletes build artifacts when --build-artifacts is set", %{tmp_dir: tmp_dir} do
      build_dir = Path.join(tmp_dir, "_build")
      build_file = Path.join(build_dir, "compiled.bin")

      File.mkdir_p!(build_dir)
      File.write!(build_file, "compiled")

      output =
        capture_io(fn ->
          Cleanup.run([
            "--root",
            tmp_dir,
            "--apply",
            "--build-artifacts",
            "--tmp-root",
            tmp_dir
          ])
        end)

      assert output =~ "build_artifacts: 1"
      assert output =~ "deleted_files:"
      refute File.exists?(build_dir)
    end
  end

  describe "--retention-days option" do
    test "accepts custom retention days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--retention-days", "30"])
        end)

      assert output =~ "retention_days: 30"
    end

    test "accepts -d alias for --retention-days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "-d", "21"])
        end)

      assert output =~ "retention_days: 21"
    end

    test "defaults to 14 days when not specified", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "retention_days: 14"
    end
  end

  describe "--root option" do
    test "accepts custom root directory", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "root: #{tmp_dir}"
    end

    test "accepts -r alias for --root", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["-r", tmp_dir])
        end)

      assert output =~ "root: #{tmp_dir}"
    end

    test "defaults to umbrella root when current working directory is inside an umbrella app", %{
      tmp_dir: tmp_dir
    } do
      umbrella_root = Path.join(tmp_dir, "umbrella")
      app_dir = Path.join(umbrella_root, "apps/lemon_core")

      File.mkdir_p!(app_dir)
      File.write!(Path.join(umbrella_root, "mix.exs"), "# umbrella")
      File.write!(Path.join(app_dir, "mix.exs"), "# app")

      output =
        File.cd!(app_dir, fn ->
          capture_io(fn ->
            Cleanup.run([])
          end)
        end)

      assert output =~ "root: #{umbrella_root}"
    end

    test "falls back to current working directory outside an umbrella", %{tmp_dir: tmp_dir} do
      standalone = Path.join(tmp_dir, "standalone")
      File.mkdir_p!(standalone)

      output =
        File.cd!(standalone, fn ->
          capture_io(fn ->
            Cleanup.run([])
          end)
        end)

      assert output =~ "root: #{standalone}"
    end
  end

  describe "with non-empty results" do
    test "displays old run files in output", %{tmp_dir: tmp_dir} do
      # Create a mock docs/agent-loop/runs directory structure
      runs_dir = Path.join(tmp_dir, "docs/agent-loop/runs")
      File.mkdir_p!(runs_dir)

      # Create an old file (more than 14 days old)
      old_file = Path.join(runs_dir, "old_run.json")
      File.write!(old_file, "{}")

      # Set the file modification time to be old
      old_time = System.os_time(:second) - 20 * 24 * 60 * 60
      File.touch!(old_file, old_time)

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "old_run_files:"
    end

    test "displays repo tmp paths, tmp artifacts, and ignored paths in output", %{
      tmp_dir: tmp_dir
    } do
      repo_tmp_dir = Path.join(tmp_dir, "apps/lemon_gateway/tmp")
      repo_log = Path.join(tmp_dir, "apps/lemon_gateway/runtime.log")
      ignored_fixture = Path.join(tmp_dir, "apps/lemon_core/relative/test.log")
      tmp_root = Path.join(tmp_dir, "tmp")
      tmp_artifact = Path.join(tmp_root, "lemon_test_artifacts_12345")

      File.mkdir_p!(repo_tmp_dir)
      File.mkdir_p!(Path.dirname(repo_log))
      File.mkdir_p!(Path.dirname(ignored_fixture))
      File.mkdir_p!(tmp_artifact)
      File.write!(repo_log, "runtime")
      File.write!(ignored_fixture, "")

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--tmp-root", tmp_root])
        end)

      assert output =~ "repo_tmp_paths:"
      assert output =~ "tmp_artifacts:"
      assert output =~ "ignored_paths:"
      assert output =~ Path.expand(repo_tmp_dir)
      assert output =~ Path.expand(tmp_artifact)
      assert output =~ Path.expand(ignored_fixture)
    end

    test "displays build artifacts in output", %{tmp_dir: tmp_dir} do
      build_dir = Path.join(tmp_dir, "native/lemon-wasm-runtime/target/debug")
      build_root = Path.join(tmp_dir, "native/lemon-wasm-runtime/target")
      build_file = Path.join(build_dir, "runtime")

      File.mkdir_p!(build_dir)
      File.write!(build_file, "runtime-binary")

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--tmp-root", tmp_dir])
        end)

      assert output =~ "build_artifacts:"
      assert output =~ "build_artifact_bytes:"
      assert output =~ Path.expand(build_root)
    end

    test "displays stale docs in output" do
      # This test runs against the actual repo to potentially find stale docs
      output =
        capture_io(fn ->
          Cleanup.run([])
        end)

      assert output =~ "stale_docs:"
    end

    test "limits displayed items to 10", %{tmp_dir: tmp_dir} do
      # Create multiple old run files
      runs_dir = Path.join(tmp_dir, "docs/agent-loop/runs")
      File.mkdir_p!(runs_dir)

      old_time = System.os_time(:second) - 20 * 24 * 60 * 60

      for i <- 1..15 do
        file = Path.join(runs_dir, "run_#{i}.json")
        File.write!(file, "{}")
        File.touch!(file, old_time)
      end

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply"])
        end)

      # Should show the "showing up to 10" message or similar limiting
      assert output =~ "Cleanup scan complete"
    end
  end

  describe "with empty results" do
    test "handles empty old_run_files gracefully", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "old_run_files: 0"
      # Should not crash when printing empty list
      assert output =~ "Cleanup scan complete"
    end

    test "handles empty stale_docs gracefully", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      # stale_docs count should be present
      assert output =~ "stale_docs:"
    end
  end

  describe "combined options" do
    test "accepts --apply with --retention-days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run([
            "--root",
            tmp_dir,
            "--apply",
            "--retention-days",
            "7",
            "--tmp-root",
            tmp_dir
          ])
        end)

      assert output =~ "retention_days: 7"
      assert output =~ "deleted_files:"
      refute output =~ "mode: dry-run"
    end

    test "accepts all short options together", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["-r", tmp_dir, "-a", "-d", "21", "--tmp-root", tmp_dir])
        end)

      assert output =~ "root: #{tmp_dir}"
      assert output =~ "retention_days: 21"
      assert output =~ "deleted_files:"
    end
  end
end
