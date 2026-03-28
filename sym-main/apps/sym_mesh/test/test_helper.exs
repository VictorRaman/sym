# By default, exclude integration tests that require external services.
ExUnit.configure(exclude: [:integration], capture_log: true)
ExUnit.start()
