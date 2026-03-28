defmodule LemonCore.Quality.PlatformCheck do
  @moduledoc """
  Validates platform-tier metadata coverage and profile policy.
  """

  alias LemonCore.Quality.PlatformManifest

  @type issue :: %{
          code: atom(),
          message: String.t(),
          app: atom() | nil,
          path: String.t() | nil
        }

  @type report :: %{
          root: String.t(),
          apps_checked: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    actual_apps = discover_apps(root)
    manifest = PlatformManifest.apps()

    issues =
      []
      |> check_missing_manifest_entries(actual_apps, manifest)
      |> check_missing_apps(actual_apps, manifest)
      |> check_entry_shapes(manifest)
      |> check_profile_policy(manifest)

    report = %{
      root: root,
      apps_checked: length(actual_apps),
      issue_count: length(issues),
      issues: Enum.reverse(issues)
    }

    if report.issue_count == 0, do: {:ok, report}, else: {:error, report}
  end

  defp discover_apps(root) do
    root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename() |> String.to_atom()))
    |> Enum.sort()
  end

  defp check_missing_manifest_entries(issues, actual_apps, manifest) do
    Enum.reduce(actual_apps, issues, fn app, acc ->
      if Map.has_key?(manifest, app) do
        acc
      else
        [
          %{
            code: :missing_platform_manifest_entry,
            message: "App is missing from LemonCore.Quality.PlatformManifest: #{app}",
            app: app,
            path: nil
          }
          | acc
        ]
      end
    end)
  end

  defp check_missing_apps(issues, actual_apps, manifest) do
    actual = MapSet.new(actual_apps)

    Enum.reduce(manifest, issues, fn {app, _entry}, acc ->
      if MapSet.member?(actual, app) do
        acc
      else
        [
          %{
            code: :stale_platform_manifest_entry,
            message: "Platform manifest references an app that does not exist under apps/: #{app}",
            app: app,
            path: nil
          }
          | acc
        ]
      end
    end)
  end

  defp check_entry_shapes(issues, manifest) do
    Enum.reduce(manifest, issues, fn {app, entry}, acc ->
      acc
      |> maybe_issue(entry.id == app, :invalid_platform_entry, "Entry id must match app key", app)
      |> maybe_issue(entry.tier in PlatformManifest.valid_tiers(), :invalid_platform_entry, "Invalid tier #{inspect(entry.tier)}", app)
      |> maybe_issue(entry.status in PlatformManifest.valid_statuses(), :invalid_platform_entry, "Invalid status #{inspect(entry.status)}", app)
      |> maybe_issue(is_binary(entry.owner) and String.trim(entry.owner) != "", :invalid_platform_entry, "Owner must be a non-empty string", app)
      |> maybe_issue(is_binary(entry.keep_reason) and String.trim(entry.keep_reason) != "", :invalid_platform_entry, "Keep reason must be a non-empty string", app)
      |> maybe_issue(is_list(entry.profiles), :invalid_platform_entry, "Profiles must be a list", app)
      |> maybe_issue(Enum.all?(entry.profiles, &(&1 in PlatformManifest.valid_profiles())), :invalid_platform_entry, "Profiles contain invalid values", app)
    end)
  end

  defp check_profile_policy(issues, manifest) do
    Enum.reduce(manifest, issues, fn {app, entry}, acc ->
      acc
      |> maybe_issue(
        not (entry.tier == :incubator and :full in entry.profiles),
        :invalid_platform_profile,
        "Incubator apps must not participate in the full runtime profile",
        app
      )
      |> maybe_issue(
        not (entry.tier == :runtime_core and entry.profiles != [:core, :platform, :full]),
        :invalid_platform_profile,
        "Runtime core apps must be present in core, platform, and full profiles",
        app
      )
      |> maybe_issue(
        not (entry.tier == :platform_runtime and entry.profiles != [:platform, :full]),
        :invalid_platform_profile,
        "Platform runtime apps must be present in platform and full profiles",
        app
      )
      |> maybe_issue(
        not (entry.tier == :default_surface and entry.profiles != [:full]),
        :invalid_platform_profile,
        "Default-surface apps must be full-profile only",
        app
      )
    end)
  end

  defp maybe_issue(issues, true, _code, _message, _app), do: issues

  defp maybe_issue(issues, false, code, message, app) do
    [%{code: code, message: message, app: app, path: nil} | issues]
  end
end
