Application.put_env(:lemon_gateway, :web_port, 0)

# Avoid poller lock collisions with any local `lemon` process that might be running while
# developers execute tests, and prevent sticky locks between `Application.stop/1` restarts.
test_artifact_root =
  System.get_env("LEMON_TEST_ARTIFACT_ROOT") ||
    Path.join(System.tmp_dir!(), "lemon_test_artifacts_#{System.unique_integer([:positive])}")

tmp_target = Path.join(test_artifact_root, "lemon_gateway_tmp")
tmp_link = Path.expand("../tmp", __DIR__)
File.mkdir_p!(tmp_target)

case File.read_link(tmp_link) do
  {:ok, ^tmp_target} ->
    :ok

  {:ok, _other} ->
    File.rm!(tmp_link)
    File.ln_s!(tmp_target, tmp_link)

  {:error, _} ->
    if File.dir?(tmp_link), do: File.rm_rf!(tmp_link)
    File.ln_s!(tmp_target, tmp_link)
end

lock_dir = Path.join(test_artifact_root, "gateway_locks")

_ = File.mkdir_p(lock_dir)
System.put_env("LEMON_LOCK_DIR", lock_dir)

Code.require_file("support/async_helpers.ex", __DIR__)

ExUnit.configure(
  capture_log: true,
  tmp_dir: Path.join(test_artifact_root, "lemon_gateway_tmp")
)

ExUnit.start()

System.at_exit(fn _ ->
  if match?({:ok, ^tmp_target}, File.read_link(tmp_link)) do
    _ = File.rm(tmp_link)
  end
end)
