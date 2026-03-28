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
             :coding_agent
           ]
  end

  test "platform profile contains only the reduced headless platform" do
    assert PlatformManifest.apps_for_profile(:platform) == [
             :lemon_core,
             :ai,
             :coding_agent,
             :lemon_gateway,
             :lemon_control_plane
           ]
  end

  test "only the reduced five-app manifest remains" do
    assert PlatformManifest.apps() |> Map.keys() |> Enum.sort() == [
             :ai,
             :coding_agent,
             :lemon_control_plane,
             :lemon_core,
             :lemon_gateway
           ]
  end

  test "current runtime contract files reference only core and platform profiles" do
    lemon_script = File.read!(Path.join(@repo_root, "bin/lemon"))

    assert lemon_script =~ "--profile"
    assert lemon_script =~ "LEMON_RUNTIME_PROFILE"
    assert lemon_script =~ "PlatformManifest.apps_for_profile"
    refute lemon_script =~ "full | platform | core"
    refute lemon_script =~ "--web-port"
    refute lemon_script =~ "--sim-port"
    refute lemon_script =~ "LEMON_WEB_PORT"
    refute lemon_script =~ "LEMON_SIM_UI_PORT"
  end

  test "market_intel shared defaults are removed from the shared config" do
    config_source = File.read!(Path.join(@repo_root, "config/config.exs"))

    refute config_source =~ "enable_dex: false"
    refute config_source =~ "enable_polymarket: false"
    refute config_source =~ "enable_twitter: false"
    refute config_source =~ "enable_onchain: false"
    refute config_source =~ "enable_commentary: false"
    refute config_source =~ "enable_scheduler: false"
  end
end
