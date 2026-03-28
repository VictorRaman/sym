# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

drop_tls_alert_decode_error = fn
  %{level: :notice, msg: {:report, %{alert: {:alert, 2, 40, _, :client, :alert_decode_error}}}},
  _state ->
    :stop

  _event, _state ->
    :ignore
end

config :logger, :default_handler,
  filters: [
    remote_gl: {&:logger_filters.remote_gl/2, :stop},
    tls_alert_decode_error: {drop_tls_alert_decode_error, :stop}
  ]

# Lane concurrency caps for CodingAgent.LaneQueue
# Keep main cap at 4 to stay within Telegram's per-chat rate limits.
# Subagent and background_exec can be higher since they don't all
# route through the same Telegram chat.
config :coding_agent, :lane_caps,
  main: 4,
  subagent: 8,
  background_exec: 4

# Default to an in-memory store. Dev/prod override to disk-backed persistence.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

import_config "#{config_env()}.exs"
