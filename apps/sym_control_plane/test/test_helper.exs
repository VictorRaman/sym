alias LemonCore.Onboarding.LogSilencer

ExUnit.configure(capture_log: true)
ExUnit.start()

# In umbrella `mix test`, other suites may have started/stopped `:lemon_gateway`
# earlier in the same BEAM. The absorbed router/channels subsystems now live
# inside that app, so restarting the single kept gateway app is the stable
# baseline for control-plane method tests.

Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.delete_env(:lemon_gateway, :telegram)

LogSilencer.with_quiet_logs(true, fn ->
  _ = Application.stop(:lemon_gateway)

  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
end)

ExUnit.after_suite(fn _ ->
  LogSilencer.with_quiet_logs(true, fn ->
    _ = Application.stop(:lemon_gateway)
  end)
end)
