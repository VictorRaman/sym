{:ok, _} = Application.ensure_all_started(:lemon_games)

ExUnit.configure(capture_log: true)
ExUnit.start()
