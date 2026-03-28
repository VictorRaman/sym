defmodule LemonRouter.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias LemonCore.Onboarding.LogSilencer

  @moduletag capture_log: true

  defp stop_application do
    LogSilencer.with_quiet_logs(true, fn ->
      Application.stop(:lemon_router)
    end)
  end

  setup do
    original_health_enabled = Application.get_env(:lemon_router, :health_enabled)
    original_health_startup_log = Application.get_env(:lemon_router, :health_startup_log)

    Application.put_env(:lemon_router, :health_enabled, true)
    Application.put_env(:lemon_router, :health_startup_log, false)

    on_exit(fn ->
      _ = stop_application()

      if is_nil(original_health_enabled) do
        Application.delete_env(:lemon_router, :health_enabled)
      else
        Application.put_env(:lemon_router, :health_enabled, original_health_enabled)
      end

      if is_nil(original_health_startup_log) do
        Application.delete_env(:lemon_router, :health_startup_log)
      else
        Application.put_env(:lemon_router, :health_startup_log, original_health_startup_log)
      end

      assert {:ok, _} = Application.ensure_all_started(:lemon_router)
    end)

    :ok
  end

  test "health server startup log can be silenced" do
    _ = stop_application()

    log =
      capture_log(fn ->
        assert {:ok, _} = Application.ensure_all_started(:lemon_router)
        assert :ok = stop_application()
      end)

    refute log =~ "Running LemonRouter.Health.Router"
  end
end
