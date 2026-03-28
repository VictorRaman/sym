defmodule Mix.Tasks.Lemon.Platform.Docs do
  use Mix.Task

  alias LemonCore.Quality.PlatformDocs

  @shortdoc "Generate platform tier docs from manifest"
  @moduledoc """
  Regenerate the generated platform-tier section of docs/platform_tiers.md.

  Usage:
    mix lemon.platform.docs
    mix lemon.platform.docs --check
    mix lemon.platform.docs --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [check: :boolean, root: :string],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    if opts[:check] do
      case PlatformDocs.check(root) do
        {:ok, _report} ->
          Mix.shell().info("[ok] platform docs are up to date")

        {:error, report} ->
          issue = List.first(report.issues)
          Mix.raise("#{issue.message} (#{issue.path})")
      end
    else
      case PlatformDocs.write(root) do
        :ok ->
          Mix.shell().info("Updated #{PlatformDocs.doc_relative_path()}")

        {:error, issue} ->
          Mix.raise("#{issue.message} (#{issue.path})")
      end
    end
  end
end
