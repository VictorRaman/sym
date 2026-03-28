defmodule LemonWeb.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    warn_if_dashboard_unprotected()

    children = [
      LemonWeb.Telemetry,
      LemonWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LemonWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LemonWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  def warn_if_dashboard_unprotected do
    endpoint_cfg = Application.get_env(:lemon_web, LemonWeb.Endpoint, [])
    access_token = Application.get_env(:lemon_web, :access_token)
    http_cfg = Keyword.get(endpoint_cfg, :http, [])

    if Keyword.get(http_cfg, :ip) == {0, 0, 0, 0} and access_token in [nil, ""] do
      Logger.warning(
        "LEMON_WEB_ACCESS_TOKEN is not configured while LemonWeb is bound to 0.0.0.0; dashboard access is effectively unauthenticated"
      )
    end
  end
end
