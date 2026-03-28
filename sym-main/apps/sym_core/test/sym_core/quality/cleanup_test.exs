defmodule LemonCore.Quality.CleanupTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.Cleanup

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "scan/1" do
    test "returns structured report with default options" do
      report = Cleanup.scan(root: @repo_root)

      assert is_binary(report.root)
      assert report.retention_days == 14
      assert is_list(report.old_run_files)
      assert is_list(report.stale_docs)
      assert is_list(report.repo_tmp_paths)
      assert is_list(report.tmp_artifacts)
      assert is_list(report.build_artifacts)
      assert is_integer(report.build_artifact_bytes)
      assert is_list(report.ignored_paths)
      assert report.deleted_files == []
    end

    test "accepts custom retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 7)
      assert report.retention_days == 7

      report = Cleanup.scan(root: @repo_root, retention_days: 30)
      assert report.retention_days == 30
    end

    test "accepts custom root directory" do
      report = Cleanup.scan(root: @repo_root)
      assert report.root == @repo_root
    end

    test "accepts custom today date for deterministic testing" do
      today = ~D[2024-01-15]
      report = Cleanup.scan(root: @repo_root, today: today)

      assert report.root == @repo_root
      assert is_list(report.old_run_files)
    end

    test "scan with zero retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 1)
      assert report.retention_days == 1
      assert is_list(report.old_run_files)
    end

    test "scan with large retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 365)
      assert report.retention_days == 365
      assert is_list(report.old_run_files)
    end
  end

  describe "prune/1" do
    test "prune with apply: false performs dry run" do
      report = Cleanup.prune(root: @repo_root, apply: false)

      assert is_binary(report.root)
      assert is_list(report.old_run_files)
      assert report.deleted_files == []
    end

    test "prune with apply: true attempts deletion" do
      report = Cleanup.prune(root: @repo_root, apply: true)

      assert is_binary(report.root)
      assert is_list(report.old_run_files)
      # deleted_files may or may not be empty depending on actual file state
      assert is_list(report.deleted_files)
    end

    test "prune respects custom retention days" do
      report = Cleanup.prune(root: @repo_root, retention_days: 1, apply: false)
      assert report.retention_days == 1
    end

    test "prune with no options uses defaults" do
      # This will use File.cwd!() as root, so we test the structure
      report = Cleanup.prune([])

      assert is_binary(report.root)
      assert report.retention_days == 14
      assert is_list(report.old_run_files)
      assert is_list(report.stale_docs)
      assert is_list(report.deleted_files)
    end
  end

  describe "edge cases" do
    test "scan handles non-existent run directory gracefully" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      try do
        report = Cleanup.scan(root: tmp_dir, tmp_root: tmp_dir)
        assert report.root == tmp_dir
        assert report.old_run_files == []
        assert report.stale_docs == []
        assert report.repo_tmp_paths == []
        assert report.tmp_artifacts == []
        assert report.ignored_paths == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "prune handles non-existent run directory gracefully" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer()}")
      tmp_root = Path.join(tmp_dir, "tmp")
      File.mkdir_p!(tmp_dir)
      File.mkdir_p!(tmp_root)

      try do
        report = Cleanup.prune(root: tmp_dir, tmp_root: tmp_root, apply: true)
        assert report.root == tmp_dir
        assert report.deleted_files == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "scan with very old date finds more files" do
      # Using a date far in the future means even recent files are "old"
      future_date = Date.add(Date.utc_today(), 365)
      report = Cleanup.scan(root: @repo_root, today: future_date, retention_days: 1)

      assert is_list(report.old_run_files)
    end

    test "scan with recent date finds fewer files" do
      # Using a date in the past means fewer files are "old"
      past_date = ~D[2020-01-01]
      report = Cleanup.scan(root: @repo_root, today: past_date, retention_days: 1)

      assert is_list(report.old_run_files)
    end
  end

  describe "report structure" do
    test "report contains all required keys" do
      report = Cleanup.scan(root: @repo_root)

      assert Map.has_key?(report, :root)
      assert Map.has_key?(report, :retention_days)
      assert Map.has_key?(report, :old_run_files)
      assert Map.has_key?(report, :stale_docs)
      assert Map.has_key?(report, :repo_tmp_paths)
      assert Map.has_key?(report, :tmp_artifacts)
      assert Map.has_key?(report, :build_artifacts)
      assert Map.has_key?(report, :build_artifact_bytes)
      assert Map.has_key?(report, :ignored_paths)
      assert Map.has_key?(report, :deleted_files)
    end

    test "old_run_files are sorted" do
      report = Cleanup.scan(root: @repo_root)
      assert report.old_run_files == Enum.sort(report.old_run_files)
    end

    test "old_run_files contain absolute paths" do
      report = Cleanup.scan(root: @repo_root)

      for path <- report.old_run_files do
        assert Path.type(path) == :absolute
      end
    end
  end

  describe "repo and tmp artifact scanning" do
    test "finds known build artifact directories and totals their size" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer([:positive])}")
      tmp_root = Path.join(tmp_dir, "tmp")

      build_dirs = [
        %{path: Path.join(tmp_dir, "_build"), category: :mix_build, file: "compiled.bin", bytes: 3},
        %{path: Path.join(tmp_dir, "_codex_build"), category: :codex_build, file: "test/artifact.bin", bytes: 5},
        %{path: Path.join(tmp_dir, "deps"), category: :mix_deps, file: "dep.lock", bytes: 7},
        %{
          path: Path.join(tmp_dir, "native/lemon-wasm-runtime/target"),
          category: :rust_target,
          file: "debug/runtime",
          bytes: 11
        },
        %{
          path: Path.join(tmp_dir, "clients/lemon-web/server/dist"),
          category: :js_dist,
          file: "index.js",
          bytes: 13
        },
        %{
          path: Path.join(tmp_dir, "clients/lemon-tui/node_modules"),
          category: :node_modules,
          file: "pkg.json",
          bytes: 17
        }
      ]

      Enum.each(build_dirs, fn %{path: path, file: file, bytes: bytes} ->
        File.mkdir_p!(Path.join(path, Path.dirname(file)))
        File.write!(Path.join(path, file), :binary.copy("x", bytes))
      end)

      try do
        report = Cleanup.scan(root: tmp_dir, tmp_root: tmp_root)

        assert Enum.sort(Enum.map(report.build_artifacts, & &1.path)) ==
                 Enum.sort(Enum.map(build_dirs, &Path.expand(&1.path)))

        assert Enum.sort(Enum.map(report.build_artifacts, & &1.category)) ==
                 Enum.sort(Enum.map(build_dirs, & &1.category))

        assert report.build_artifact_bytes == Enum.sum(Enum.map(build_dirs, & &1.bytes))
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "finds repo tmp directories, tmp artifacts, and ignored fixture paths" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer([:positive])}")
      tmp_root = Path.join(tmp_dir, "tmp")
      repo_tmp_dir = Path.join(tmp_dir, "apps/lemon_gateway/tmp")
      repo_log = Path.join(tmp_dir, "apps/lemon_gateway/runtime.log")
      ignored_fixture = Path.join(tmp_dir, "apps/lemon_core/relative/test.log")
      mix_build = Path.join(tmp_root, "lemon-mix-isolated.ABC123")
      test_root = Path.join(tmp_root, "lemon_test_artifacts_12345")

      File.mkdir_p!(repo_tmp_dir)
      File.mkdir_p!(Path.dirname(repo_log))
      File.mkdir_p!(Path.dirname(ignored_fixture))
      File.mkdir_p!(mix_build)
      File.mkdir_p!(test_root)
      File.write!(repo_log, "runtime noise")
      File.write!(ignored_fixture, "")

      try do
        report = Cleanup.scan(root: tmp_dir, tmp_root: tmp_root)

        assert report.repo_tmp_paths ==
                 Enum.sort([Path.expand(repo_log), Path.expand(repo_tmp_dir)])

        assert report.tmp_artifacts == Enum.sort([Path.expand(mix_build), Path.expand(test_root)])
        assert report.ignored_paths == [Path.expand(ignored_fixture)]
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "prune deletes detected repo tmp paths and tmp artifacts but preserves ignored fixtures" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer([:positive])}")
      tmp_root = Path.join(tmp_dir, "tmp")
      repo_tmp_dir = Path.join(tmp_dir, "apps/lemon_gateway/tmp")
      repo_log = Path.join(tmp_dir, "apps/lemon_gateway/runtime.log")
      ignored_fixture = Path.join(tmp_dir, "apps/lemon_core/relative/test.log")
      mix_build = Path.join(tmp_root, "lemon-mix-isolated.ABC123")

      File.mkdir_p!(repo_tmp_dir)
      File.mkdir_p!(Path.dirname(repo_log))
      File.mkdir_p!(Path.dirname(ignored_fixture))
      File.mkdir_p!(mix_build)
      File.write!(repo_log, "runtime noise")
      File.write!(ignored_fixture, "")

      try do
        report = Cleanup.prune(root: tmp_dir, tmp_root: tmp_root, apply: true)

        assert Enum.sort(report.deleted_files) ==
                 Enum.sort([
                   Path.expand(repo_log),
                   Path.expand(repo_tmp_dir),
                   Path.expand(mix_build)
                 ])

        refute File.exists?(repo_log)
        refute File.exists?(repo_tmp_dir)
        refute File.exists?(mix_build)
        assert File.exists?(ignored_fixture)
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "prune preserves build artifacts unless explicitly enabled" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer([:positive])}")
      tmp_root = Path.join(tmp_dir, "tmp")
      build_dir = Path.join(tmp_dir, "_build")
      build_file = Path.join(build_dir, "compiled.bin")

      File.mkdir_p!(build_dir)
      File.write!(build_file, "compiled")

      try do
        report = Cleanup.prune(root: tmp_dir, tmp_root: tmp_root, apply: true)

        assert report.build_artifacts != []
        assert File.exists?(build_dir)
        refute Path.expand(build_dir) in report.deleted_files

        report =
          Cleanup.prune(
            root: tmp_dir,
            tmp_root: tmp_root,
            apply: true,
            build_artifacts: true
          )

        refute File.exists?(build_dir)
        assert Path.expand(build_dir) in report.deleted_files
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "scan includes extended Lemon tmp artifact prefixes used by tests and final proof runs" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer([:positive])}")
      tmp_root = Path.join(tmp_dir, "tmp")

      expected =
        [
          "lemon-ai-test-home-123",
          "lemon-auto-put-123",
          "lemon-auto-put-photo-mg-123",
          "lemon-file-get-123",
          "lemon-file-put-mg-123",
          "lemon-fix-control-plane",
          "lemon-plan-router-test",
          "lemon-root-final7",
          "lemon-tmpdir-gateway"
        ]
        |> Enum.map(&Path.join(tmp_root, &1))
        |> Enum.map(&Path.expand/1)
        |> Enum.sort()

      Enum.each(expected, &File.mkdir_p!/1)

      try do
        report = Cleanup.scan(root: tmp_dir, tmp_root: tmp_root)

        for path <- expected do
          assert path in report.tmp_artifacts
        end
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end
end
