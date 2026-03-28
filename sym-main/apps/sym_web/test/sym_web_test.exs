defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "application starts successfully" do
    # The application should be running
    assert Application.started_applications()
           |> Enum.any?(fn {app, _, _} -> app == :lemon_web end)
  end

  test "endpoint configuration exists" do
    config = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    assert is_list(config)
    assert config[:url] || config[:http]
  end

  test "router is configured" do
    # The router module should exist and be loadable
    assert Code.ensure_loaded?(LemonWeb.Router)
  end

  test "session live module exists" do
    # The SessionLive module should exist
    assert Code.ensure_loaded?(LemonWeb.SessionLive)
  end

  test "warns when the dashboard is exposed without an access token" do
    original_endpoint = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    original_token = Application.get_env(:lemon_web, :access_token)

    Application.put_env(:lemon_web, LemonWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4080])
    Application.put_env(:lemon_web, :access_token, nil)

    on_exit(fn ->
      Application.put_env(:lemon_web, LemonWeb.Endpoint, original_endpoint)
      Application.put_env(:lemon_web, :access_token, original_token)
    end)

    log =
      capture_log(fn ->
        LemonWeb.Application.warn_if_dashboard_unprotected()
      end)

    assert log =~ "LEMON_WEB_ACCESS_TOKEN is not configured"
  end
end
