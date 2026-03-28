alias LemonCore.Onboarding.LogSilencer

Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.delete_env(:lemon_gateway, :telegram)

# Ensure runtime dependencies are started for automation tests.
LogSilencer.with_quiet_logs(true, fn ->
  _ = Application.stop(:lemon_gateway)
  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
end)

ExUnit.configure(capture_log: true)
ExUnit.start()

ExUnit.after_suite(fn _ ->
  LogSilencer.with_quiet_logs(true, fn ->
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_gateway)
  end)
end)
