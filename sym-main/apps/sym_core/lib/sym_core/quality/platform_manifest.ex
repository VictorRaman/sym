defmodule LemonCore.Quality.PlatformManifest do
  @moduledoc """
  Canonical platform product-tier metadata and runtime profile definitions.

  This module is the single source of truth for:
  - app grading (core/platform/default-surface/incubator)
  - maturity status
  - profile membership (`core`, `platform`, `full`)
  - ownership and keep-rationale used by docs and quality checks
  """

  @valid_tiers [:runtime_core, :platform_runtime, :default_surface, :incubator]
  @valid_statuses [:stable, :incubating, :sidecar, :tooling_only]
  @valid_profiles [:core, :platform, :full]

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
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Shared config, store, pubsub, browser bridge, and quality harness."
    },
    %{
      id: :ai,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Unified provider runtime for every AI-backed execution path."
    },
    %{
      id: :agent_core,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Shared BEAM agent loop and CLI-runner substrate."
    },
    %{
      id: :lemon_mesh,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Durable mailbox and handoff substrate used by coding runtime."
    },
    %{
      id: :lemon_skills,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Skill registry is part of the core prompt/bootstrap contract."
    },
    %{
      id: :coding_agent,
      tier: :runtime_core,
      status: :stable,
      profiles: [:core, :platform, :full],
      owner: "@platform-core",
      keep_reason: "Primary coding runtime and tool-execution engine."
    },
    %{
      id: :lemon_gateway,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform, :full],
      owner: "@platform-runtime",
      keep_reason: "Engine and transport execution runtime for platform entrypoints."
    },
    %{
      id: :lemon_router,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform, :full],
      owner: "@platform-runtime",
      keep_reason: "Routing, run orchestration, conversation state, and queue semantics."
    },
    %{
      id: :lemon_channels,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform, :full],
      owner: "@platform-runtime",
      keep_reason: "Outbound presentation and channel adapters for real transports."
    },
    %{
      id: :lemon_control_plane,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform, :full],
      owner: "@platform-runtime",
      keep_reason: "Primary RPC/WebSocket control surface for attached clients."
    },
    %{
      id: :lemon_automation,
      tier: :platform_runtime,
      status: :stable,
      profiles: [:platform, :full],
      owner: "@platform-runtime",
      keep_reason: "Scheduled submissions and heartbeats for long-running platform tasks."
    },
    %{
      id: :lemon_web,
      tier: :default_surface,
      status: :stable,
      profiles: [:full],
      owner: "@product-surface",
      keep_reason: "Default LiveView dashboard and public games spectator surface."
    },
    %{
      id: :lemon_games,
      tier: :default_surface,
      status: :stable,
      profiles: [:full],
      owner: "@product-surface",
      keep_reason: "Backs the public games platform exposed by lemon_web."
    },
    %{
      id: :lemon_sim,
      tier: :default_surface,
      status: :stable,
      profiles: [:full],
      owner: "@product-surface",
      keep_reason: "Simulation contracts consumed by the default sim UI."
    },
    %{
      id: :lemon_sim_ui,
      tier: :default_surface,
      status: :stable,
      profiles: [:full],
      owner: "@product-surface",
      keep_reason: "Default-start sim surface for simulation harnesses."
    },
    %{
      id: :coding_agent_ui,
      tier: :incubator,
      status: :tooling_only,
      profiles: [],
      owner: "@incubator",
      keep_reason: "Thin RPC/UI abstraction kept for tooling compatibility, not platform runtime."
    },
    %{
      id: :lemon_mcp,
      tier: :incubator,
      status: :incubating,
      profiles: [],
      owner: "@incubator",
      keep_reason: "MCP bridge remains exploratory and is not part of the default runtime."
    },
    %{
      id: :lemon_services,
      tier: :incubator,
      status: :sidecar,
      profiles: [],
      owner: "@incubator",
      keep_reason: "Standalone service manager kept as a sidecar capability outside default runtime."
    },
    %{
      id: :market_intel,
      tier: :incubator,
      status: :incubating,
      profiles: [],
      owner: "@incubator",
      keep_reason: "Experimental market-data/commentary product line kept outside default runtime."
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
      nil -> apps_for_profile(:full)
      atom -> apps_for_profile(atom)
    end
  end

  def apps_for_profile(profile) when profile in @valid_profiles do
    @entries
    |> Enum.filter(&(profile in &1.profiles))
    |> Enum.map(& &1.id)
  end

  def apps_for_profile(_), do: apps_for_profile(:full)

  @spec default_runtime?(atom()) :: boolean()
  def default_runtime?(app) when is_atom(app) do
    case get(app) do
      %{profiles: profiles} -> :full in profiles
      nil -> false
    end
  end
end
