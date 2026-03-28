defmodule LemonCore.Quality.PlatformManifest do
  @moduledoc """
  Canonical platform product-tier metadata and runtime profile definitions.

  This module is the single source of truth for:
  - app grading (core/platform)
  - maturity status
  - profile membership (`core`, `platform`)
  - ownership and keep-rationale used by docs and quality checks
  """

  @valid_tiers [:runtime_core, :platform_runtime]
  @valid_statuses [:stable]
  @valid_profiles [:core, :platform]

  @type entry :: %{
          id: atom(),
          tier: atom(),
          status: atom(),
          profiles: [atom()],
          owner: String.t(),
          keep_reason: String.t()
        }

  @entries [
    %{
      id: :lemon_core,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform],
      owner: "@platform-core",
      keep_reason: "Shared config, store, secrets, persistence, and quality harness."
    },
    %{
      id: :ai,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform],
      owner: "@platform-core",
      keep_reason: "Unified provider runtime for every AI-backed execution path."
    },
    %{
      id: :coding_agent,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform],
      owner: "@platform-core",
      keep_reason: "Primary coding runtime with absorbed agent loop, skills, and session tooling."
    },
    %{
      id: :lemon_gateway,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform],
      owner: "@platform-runtime",
      keep_reason: "Unified platform runtime with absorbed routing, channel delivery, and automation."
    },
    %{
      id: :lemon_control_plane,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform],
      owner: "@platform-runtime",
      keep_reason: "Canonical RPC and WebSocket control surface for the headless platform."
    }
  ]

  @app_map Map.new(@entries, &{&1.id, &1})

  @spec apps() :: %{atom() => entry()}
  def apps, do: @app_map

  @spec get(atom()) :: entry() | nil
  def get(app) when is_atom(app), do: Map.get(@app_map, app)

  @spec entries() :: [entry()]
  def entries, do: @entries

  @spec valid_tiers() :: [atom()]
  def valid_tiers, do: @valid_tiers

  @spec valid_statuses() :: [atom()]
  def valid_statuses, do: @valid_statuses

  @spec valid_profiles() :: [atom()]
  def valid_profiles, do: @valid_profiles

  @spec apps_for_profile(atom() | String.t()) :: [atom()]
  def apps_for_profile(profile) when is_binary(profile) do
    normalized =
      profile
      |> String.trim()
      |> String.downcase()

    case Enum.find(@valid_profiles, &(Atom.to_string(&1) == normalized)) do
      nil -> apps_for_profile(:platform)
      atom -> apps_for_profile(atom)
    end
  end

  def apps_for_profile(profile) when profile in @valid_profiles do
    @entries
    |> Enum.filter(&(profile in &1.profiles))
    |> Enum.map(& &1.id)
  end

  def apps_for_profile(_), do: apps_for_profile(:platform)

  @spec default_runtime?(atom()) :: boolean()
  def default_runtime?(app) when is_atom(app) do
    case get(app) do
      %{profiles: profiles} -> :platform in profiles
      nil -> false
    end
  end
end
