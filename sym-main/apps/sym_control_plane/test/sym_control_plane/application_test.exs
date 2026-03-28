defmodule LemonControlPlane.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias LemonCore.Onboarding.LogSilencer

  @moduletag capture_log: true

  defp stop_application do
    LogSilencer.with_quiet_logs(true, fn ->
      Application.stop(:lemon_control_plane)
    end)
  end

  setup do
    Application.put_env(:lemon_control_plane, :startup_log, false)

    on_exit(fn ->
      _ = stop_application()
      Application.delete_env(:lemon_control_plane, :startup_log)
    end)

    :ok
  end

  test "http server startup log can be silenced" do
    _ = stop_application()

    log =
      capture_log(fn ->
        assert {:ok, _} = Application.ensure_all_started(:lemon_control_plane)
        assert :ok = stop_application()
      end)

    refute log =~ "Running LemonControlPlane.HTTP.Router"
  end
end
