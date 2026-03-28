import Config

# Keep Logger defaults in tests: several test suites assert on `:info`/`:warning`
# messages via `ExUnit.CaptureLog`. If you need quieter output, prefer per-test
# `capture_log/2` or configure console formatting in CI.
config :logger, :default_handler, level: :info

test_artifact_root =
  case System.get_env("LEMON_TEST_ARTIFACT_ROOT") do
    value when is_binary(value) and value != "" ->
      Path.expand(value)

    _ ->
      case System.get_env("MIX_BUILD_ROOT") do
        value when is_binary(value) and value != "" ->
          Path.join(Path.expand(value), "lemon_test_artifacts")

        _ ->
          Path.join(
            System.tmp_dir!(),
            "lemon_test_artifacts_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
          )
      end
  end

File.mkdir_p!(test_artifact_root)
System.put_env("LEMON_TEST_ARTIFACT_ROOT", test_artifact_root)

System.at_exit(fn _ ->
  _ = File.rm_rf(test_artifact_root)
end)

# Isolate on-disk poller locks per `mix test` OS process. This prevents cross-process
# test interference if multiple `mix test` commands run concurrently on the same host.
lock_dir = Path.join(test_artifact_root, "locks")
File.mkdir_p!(lock_dir)
System.put_env("LEMON_LOCK_DIR", lock_dir)

# Tests must not depend on or mutate a developer's persistent state on disk.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

# Enable test-mode gateway config path (full-replacement via app env).
config :lemon_core, config_test_mode: true

# Tests mutate HOME/config files frequently; always re-stat config paths on each call.
config :lemon_core, LemonCore.ConfigCache, mtime_check_interval_ms: 0

config :lemon_core, LemonCore.RunHistoryStore, path: Path.join(test_artifact_root, "run_history")

# Avoid writing dets / sessions / global config under ~/.lemon/agent during tests.
config :coding_agent,
       :agent_dir,
       Path.join(test_artifact_root, "agent")

# Avoid copying repo-bundled skills into user config during unrelated test suites.
config :lemon_skills, seed_builtin_skills: false
config :lemon_skills, :http_client, LemonSkills.HttpClient.Mock

# Prevent unit tests from starting real/interactive transports based on a developer's
# local TOML config. Individual test suites can override these as needed and restart
# the application under test.
config :lemon_gateway, LemonGateway.Config,
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon",
  bindings: [],
  projects: %{}

config :lemon_gateway, :health_startup_log, false
config :lemon_router, :health_startup_log, false
config :lemon_control_plane, :startup_log, false

config :lemon_gateway, :engines, [
  LemonGateway.Engines.Lemon,
  LemonGateway.Engines.Echo,
  LemonGateway.Engines.Codex,
  LemonGateway.Engines.Claude,
  LemonGateway.Engines.Opencode,
  LemonGateway.Engines.Pi,
  LemonGateway.Engines.Kimi
]

config :lemon_gateway, :telegram, nil

# Keep browser.request parity tests node-only; don't try to auto-fallback to the local driver in tests.
config :lemon_control_plane, :browser_local_fallback, false

# Disable all MarketIntel ingestors and workers in test.
# Prevents Exqlite connection errors and external API polling during test runs.
# Individual MarketIntel test suites can override specific flags as needed.
config :market_intel, MarketIntel.Repo,
  database: Path.join(test_artifact_root, "market_intel.db"),
  pool_size: 1

config :market_intel, :ingestion, %{
  enable_dex: false,
  enable_polymarket: false,
  enable_twitter: false,
  enable_onchain: false,
  enable_commentary: false,
  enable_scheduler: false
}
