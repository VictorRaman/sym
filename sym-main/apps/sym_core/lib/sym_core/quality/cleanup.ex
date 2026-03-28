defmodule LemonCore.Quality.Cleanup do
  @moduledoc """
  Scans and prunes stale Lemon residue.

  Default mode is dry-run and reports:
  - stale docs from `LemonCore.Quality.DocsCheck`
  - run artifacts older than retention window
  - repo-local tmp/log residue under the umbrella
  - Lemon-owned temporary artifacts under `/tmp`
  - local build artifacts that can be safely regenerated
  """

  alias LemonCore.Quality.DocsCheck

  @default_retention_days 14
  @default_tmp_root System.tmp_dir!()
  @ignored_repo_relative_paths [
    Path.join(["apps", "lemon_core", "relative", "test.log"])
  ]
  @tmp_patterns [
    "lemon-ai-test-home-*",
    "lemon-auto-put*",
    "lemon-file-get*",
    "lemon-file-put*",
    "lemon-fix-*",
    "lemon-mix-isolated.*",
    "lemon-plan-*",
    "lemon_agent_test_*",
    "coding_agent_test_home_*",
    "lemon_skills_test_home_*",
    "lemon_locks_test_*",
    "lemon_test_locks_*",
    "market_intel_test_*.db",
    "cli_runner_stderr_*.log",
    "cli_runner_stdin_*.txt",
    "pi-bash-*.log",
    "lemon_checkpoints",
    "lemon_test_artifacts_*",
    "lemon-root-final*",
    "lemon-root-cache",
    "lemon-tmpdir*",
    "lemon-zero-log-*"
  ]
  @build_artifact_patterns [
    {:mix_build, "_build"},
    {:codex_build, "_codex_build"},
    {:mix_deps, "deps"},
    {:rust_target, "native/*/target"},
    {:js_dist, "clients/*/dist"},
    {:js_dist, "clients/*/*/dist"},
    {:node_modules, "node_modules"},
    {:node_modules, "clients/*/node_modules"},
    {:node_modules, "clients/*/*/node_modules"}
  ]

  @type build_artifact :: %{
          path: String.t(),
          bytes: non_neg_integer(),
          category: atom()
        }

  @type report :: %{
          root: String.t(),
          retention_days: pos_integer(),
          old_run_files: [String.t()],
          stale_docs: [map()],
          repo_tmp_paths: [String.t()],
          tmp_artifacts: [String.t()],
          build_artifacts: [build_artifact()],
          build_artifact_bytes: non_neg_integer(),
          ignored_paths: [String.t()],
          deleted_files: [String.t()]
        }

  @type scan_opts :: [
          root: String.t(),
          retention_days: pos_integer(),
          today: Date.t(),
          tmp_root: String.t(),
          build_artifacts: boolean(),
          apply: boolean()
        ]

  @spec default_root(String.t()) :: String.t()
  def default_root(cwd \\ File.cwd!()) do
    cwd = Path.expand(cwd)
    find_umbrella_root(cwd) || cwd
  end

  @doc """
  Scans for stale docs and old run files without deleting anything.

  Returns a report with the following keys:
    * `:root` - the root directory scanned
    * `:retention_days` - the retention period used
    * `:old_run_files` - list of file paths older than retention_days
    * `:stale_docs` - list of stale documentation entries
    * `:repo_tmp_paths` - repo-local tmp/log residue paths
    * `:tmp_artifacts` - Lemon-owned temporary artifacts under `tmp_root`
    * `:build_artifacts` - local build artifact directories that can be regenerated
    * `:build_artifact_bytes` - total bytes used by `:build_artifacts`
    * `:ignored_paths` - recognized fixture paths intentionally excluded from deletion
    * `:deleted_files` - empty list (always empty for scan)

  ## Options
    * `:root` - root directory to scan (defaults to current working directory)
    * `:retention_days` - number of days to retain files (defaults to 14)
    * `:today` - date to use as reference (defaults to today, useful for testing)
    * `:tmp_root` - temporary directory root to scan (defaults to `System.tmp_dir!/0`)
  """
  @spec scan(scan_opts()) :: report()
  def scan(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    today = Keyword.get(opts, :today, Date.utc_today())
    tmp_root = Keyword.get(opts, :tmp_root, @default_tmp_root)

    old_run_files = find_old_run_files(root, retention_days, today)
    stale_docs = find_stale_docs(root, today)
    {repo_tmp_paths, ignored_paths} = find_repo_tmp_paths(root)
    tmp_artifacts = find_tmp_artifacts(tmp_root)
    build_artifacts = find_build_artifacts(root)

    %{
      root: Path.expand(root),
      retention_days: retention_days,
      old_run_files: old_run_files,
      stale_docs: stale_docs,
      repo_tmp_paths: repo_tmp_paths,
      tmp_artifacts: tmp_artifacts,
      build_artifacts: build_artifacts,
      build_artifact_bytes: Enum.reduce(build_artifacts, 0, &(&1.bytes + &2)),
      ignored_paths: ignored_paths,
      deleted_files: []
    }
  end

  @doc """
  Scans and optionally deletes stale docs and old run files.

  When `:apply` is `true`, actually deletes the old run files found.
  When `:apply` is `false` (default), performs a dry run.

  Returns a report with the following keys:
    * `:root` - the root directory scanned
    * `:retention_days` - the retention period used
    * `:old_run_files` - list of file paths older than retention_days
    * `:stale_docs` - list of stale documentation entries
    * `:repo_tmp_paths` - repo-local tmp/log residue paths
    * `:tmp_artifacts` - Lemon-owned temporary artifacts under `tmp_root`
    * `:build_artifacts` - local build artifact directories that can be regenerated
    * `:build_artifact_bytes` - total bytes used by `:build_artifacts`
    * `:ignored_paths` - recognized fixture paths intentionally excluded from deletion
    * `:deleted_files` - list of files actually deleted (only when apply: true)

  ## Options
    * `:root` - root directory to scan (defaults to current working directory)
    * `:retention_days` - number of days to retain files (defaults to 14)
    * `:today` - date to use as reference (defaults to today, useful for testing)
    * `:tmp_root` - temporary directory root to scan (defaults to `System.tmp_dir!/0`)
    * `:build_artifacts` - if true, delete build artifacts in addition to runtime residue
    * `:apply` - if true, actually delete files; if false, dry run (defaults to false)
  """
  @spec prune(scan_opts()) :: report()
  def prune(opts \\ []) do
    report = scan(opts)
    apply_changes = Keyword.get(opts, :apply, false)
    delete_build_artifacts? = Keyword.get(opts, :build_artifacts, false)

    if apply_changes do
      build_artifact_paths =
        if delete_build_artifacts? do
          Enum.map(report.build_artifacts, & &1.path)
        else
          []
        end

      deleted_files =
        (report.old_run_files ++ report.repo_tmp_paths ++ report.tmp_artifacts ++ build_artifact_paths)
        |> Enum.uniq()
        |> Enum.filter(&File.exists?/1)
        |> Enum.reduce([], fn path, acc ->
          if delete_path(path) do
            [path | acc]
          else
            acc
          end
        end)
        |> Enum.sort()

      %{report | deleted_files: deleted_files}
    else
      report
    end
  end

  @spec find_stale_docs(String.t(), Date.t()) :: [map()]
  defp find_stale_docs(root, today) do
    case DocsCheck.run(root: root, today: today) do
      {:ok, _report} ->
        []

      {:error, report} ->
        Enum.filter(report.issues, &(&1.code == :stale_doc))
    end
  end

  @spec find_repo_tmp_paths(String.t()) :: {[String.t()], [String.t()]}
  defp find_repo_tmp_paths(root) do
    root = Path.expand(root)

    candidates =
      (repo_tmp_candidates(root) ++ repo_log_candidates(root))
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.split_with(candidates, &ignored_repo_path?(&1, root))
    |> then(fn {ignored, kept} -> {kept, ignored} end)
  end

  defp repo_tmp_candidates(root) do
    Path.wildcard(Path.join(root, "apps/*/tmp"))
  end

  defp repo_log_candidates(root) do
    [
      Path.wildcard(Path.join(root, "apps/*/*.log")),
      Path.wildcard(Path.join(root, "apps/*/*/*.log"))
    ]
    |> List.flatten()
  end

  @spec find_tmp_artifacts(String.t()) :: [String.t()]
  defp find_tmp_artifacts(tmp_root) do
    tmp_root = Path.expand(tmp_root)

    @tmp_patterns
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(tmp_root, pattern)) end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec find_build_artifacts(String.t()) :: [build_artifact()]
  defp find_build_artifacts(root) do
    root = Path.expand(root)

    @build_artifact_patterns
    |> Enum.flat_map(fn {category, pattern} ->
      root
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.map(fn path ->
        %{path: Path.expand(path), category: category}
      end)
    end)
    |> Enum.uniq_by(& &1.path)
    |> Enum.filter(fn %{path: path} -> File.dir?(path) end)
    |> Enum.map(fn artifact ->
      Map.put(artifact, :bytes, path_size_bytes(artifact.path))
    end)
    |> Enum.sort_by(& &1.path)
  end

  @spec find_old_run_files(String.t(), pos_integer(), Date.t()) :: [String.t()]
  defp find_old_run_files(root, retention_days, today) do
    cutoff = Date.add(today, -retention_days)

    root
    |> Path.join("docs/agent-loop/runs/*")
    |> Path.wildcard()
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{mtime: mtime}} ->
          mtime
          |> NaiveDateTime.from_erl!()
          |> NaiveDateTime.to_date()
          |> Date.compare(cutoff) == :lt

        _ ->
          false
      end
    end)
    |> Enum.sort()
  end

  defp ignored_repo_path?(path, root) do
    relative = Path.relative_to(path, root)
    relative in @ignored_repo_relative_paths
  end

  defp delete_path(path) do
    _ = File.rm_rf(path)
    not File.exists?(path)
  end

  defp path_size_bytes(path) do
    case fast_path_size_bytes(path) do
      {:ok, size} ->
        size

      :error ->
        slow_path_size_bytes(path)
    end
  end

  defp fast_path_size_bytes(path) do
    with du when is_binary(du) <- System.find_executable("du"),
         {output, 0} <- System.cmd(du, ["-sb", path], stderr_to_stdout: true),
         [size | _rest] <- String.split(String.trim(output), ~r/\s+/, parts: 2),
         {parsed, ""} <- Integer.parse(size) do
      {:ok, parsed}
    else
      _ -> :error
    end
  end

  defp slow_path_size_bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path
        |> File.ls()
        |> case do
          {:ok, entries} ->
            Enum.reduce(entries, 0, fn entry, acc ->
              acc + slow_path_size_bytes(Path.join(path, entry))
            end)

          _ ->
            0
        end

      {:ok, %File.Stat{size: size}} when is_integer(size) ->
        size

      _ ->
        0
    end
  end

  defp find_umbrella_root(path) do
    cond do
      umbrella_root?(path) -> path
      parent_root?(path) -> nil
      true -> find_umbrella_root(Path.dirname(path))
    end
  end

  defp umbrella_root?(path) do
    File.regular?(Path.join(path, "mix.exs")) and File.dir?(Path.join(path, "apps"))
  end

  defp parent_root?(path) do
    Path.dirname(path) == path
  end
end
