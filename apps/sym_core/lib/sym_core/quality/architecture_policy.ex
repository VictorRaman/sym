defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Canonical source of truth for architecture dependency policy.

  This module defines which umbrella apps may directly depend on which other
  umbrella apps. Human-readable docs and machine checks must derive from this
  module rather than duplicating policy in multiple places.
  """

  @type app :: atom()
  @type dependency_map :: %{optional(app()) => [app()]}

  @allowed_direct_deps %{
    ai: [:lemon_core],
    coding_agent: [:ai, :lemon_core],
    lemon_control_plane: [:ai, :coding_agent, :lemon_core, :lemon_gateway],
    lemon_core: [],
    lemon_gateway: [:ai, :coding_agent, :lemon_core]
  }

  @spec allowed_direct_deps() :: dependency_map()
  def allowed_direct_deps do
    @allowed_direct_deps
    |> Enum.map(fn {app, deps} -> {app, Enum.sort(deps)} end)
    |> Map.new()
  end
end
