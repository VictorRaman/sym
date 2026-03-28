defmodule Mix.Tasks.Lemon.Cleanup do
  use Mix.Task

  alias LemonCore.Quality.Cleanup

  @shortdoc "Scan or prune Lemon residue"
  @moduledoc """
  Scan cleanup candidates and optionally prune old run artifacts and Lemon-owned
  temporary residue under `/tmp`. Build artifacts are always reported, but are
  only deleted when `--build-artifacts` is passed alongside `--apply`.

  Usage:
    mix lemon.cleanup
    mix lemon.cleanup --retention-days 21
    mix lemon.cleanup --apply
    mix lemon.cleanup --apply --build-artifacts
    mix lemon.cleanup --apply --retention-days 30
    mix lemon.cleanup --tmp-root /tmp
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          apply: :boolean,
          build_artifacts: :boolean,
          retention_days: :integer,
          root: :string,
          tmp_root: :string
        ],
        aliases: [a: :apply, d: :retention_days, r: :root]
      )

    root = opts[:root] || Cleanup.default_root(File.cwd!())
    apply_changes = opts[:apply] || false
    delete_build_artifacts = opts[:build_artifacts] || false
    retention_days = opts[:retention_days] || 14
    tmp_root = opts[:tmp_root] || System.tmp_dir!()

    report =
      Cleanup.prune(
        root: root,
        apply: apply_changes,
        build_artifacts: delete_build_artifacts,
        retention_days: retention_days,
        tmp_root: tmp_root
      )

    Mix.shell().info("Cleanup scan complete")
    Mix.shell().info("- root: #{report.root}")
    Mix.shell().info("- retention_days: #{report.retention_days}")
    Mix.shell().info("- old_run_files: #{length(report.old_run_files)}")
    Mix.shell().info("- stale_docs: #{length(report.stale_docs)}")
    Mix.shell().info("- repo_tmp_paths: #{length(report.repo_tmp_paths)}")
    Mix.shell().info("- tmp_artifacts: #{length(report.tmp_artifacts)}")
    Mix.shell().info("- build_artifacts: #{length(report.build_artifacts)}")
    Mix.shell().info("- build_artifact_bytes: #{report.build_artifact_bytes}")
    Mix.shell().info("- ignored_paths: #{length(report.ignored_paths)}")

    if apply_changes do
      Mix.shell().info("- deleted_files: #{length(report.deleted_files)}")

      unless delete_build_artifacts do
        Mix.shell().info("- note: build artifacts are report-only unless --build-artifacts is passed")
      end
    else
      Mix.shell().info(
        "- mode: dry-run (use --apply to delete old run files; add --build-artifacts to delete build artifacts)"
      )
    end

    print_sample("Old run files", report.old_run_files)
    print_sample("Stale docs", Enum.map(report.stale_docs, &format_stale_doc/1))
    print_sample("Repo tmp paths", report.repo_tmp_paths)
    print_sample("Tmp artifacts", report.tmp_artifacts)
    print_build_artifacts(report.build_artifacts)
    print_sample("Ignored paths", report.ignored_paths)
  end

  defp print_sample(_label, []), do: :ok

  defp print_sample(label, values) do
    Mix.shell().info("#{label} (showing up to 10):")

    values
    |> Enum.take(10)
    |> Enum.each(fn value -> Mix.shell().info("  - #{value}") end)
  end

  defp print_build_artifacts([]), do: :ok

  defp print_build_artifacts(artifacts) do
    Mix.shell().info("Build artifacts (showing up to 10):")

    artifacts
    |> Enum.sort_by(fn artifact -> {-artifact.bytes, artifact.path} end)
    |> Enum.take(10)
    |> Enum.each(fn artifact ->
      Mix.shell().info("  - [#{artifact.category}] #{artifact.path} (#{artifact.bytes} bytes)")
    end)
  end

  defp format_stale_doc(issue) do
    "#{issue.path}: #{issue.message}"
  end
end
