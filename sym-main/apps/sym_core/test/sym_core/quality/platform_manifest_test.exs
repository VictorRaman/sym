defmodule LemonCore.Quality.PlatformManifestTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitecturePolicy
  alias LemonCore.Quality.PlatformManifest

  @repo_root Path.expand("../../../../..", __DIR__)

  test "manifest covers every umbrella app in the architecture policy" do
    manifest_apps = PlatformManifest.apps() |> Map.keys() |> Enum.sort()
    policy_apps = ArchitecturePolicy.allowed_direct_deps() |> Map.keys() |> Enum.sort()

    assert manifest_apps == policy_apps
  end

  test "every manifest entry includes required metadata" do
    assert Enum.all?(PlatformManifest.apps(), fn {app, entry} ->
             app == entry.id and
               is_atom(entry.tier) and
               is_atom(entry.status) and
               is_binary(entry.owner) and
               is_binary(entry.keep_reason) and
               is_list(entry.profiles)
           end)
  end

  test "core profile contains only runtime-core apps" do
    assert PlatformManifest.apps_for_profile(:core) == [
             :lemon_core,
             :ai,
             :agent_core,
             :lemon_mesh,
             :lemon_skills,
             :coding_agent
           ]
  end

  test "full profile excludes incubator and sidecar apps" do
    full_apps = PlatformManifest.apps_for_profile(:full)

    refute :market_intel in full_apps
    refute :lemon_mcp in full_apps
    refute :lemon_services in full_apps
    refute :coding_agent_ui in full_apps
  end

  test "current runtime contract files reference runtime profile support" do
    lemon_script = File.read!(Path.join(@repo_root, "bin/lemon"))

    assert lemon_script =~ "--profile"
    assert lemon_script =~ "LEMON_RUNTIME_PROFILE"
    assert lemon_script =~ "PlatformManifest.apps_for_profile"
  end

  test "market_intel shared defaults are explicit opt-in" do
    config_source = File.read!(Path.join(@repo_root, "config/config.exs"))

    assert config_source =~ "enable_dex: false"
    assert config_source =~ "enable_polymarket: false"
    assert config_source =~ "enable_twitter: false"
    assert config_source =~ "enable_onchain: false"
    assert config_source =~ "enable_commentary: false"
    assert config_source =~ "enable_scheduler: false"
  end
end
