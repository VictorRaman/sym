test_artifact_root =
  System.get_env("LEMON_TEST_ARTIFACT_ROOT") ||
    Path.join(System.tmp_dir!(), "lemon_test_artifacts_#{System.unique_integer([:positive])}")

tmp_target = Path.join(test_artifact_root, "lemon_skills_tmp")
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

ExUnit.configure(
  capture_log: true,
  tmp_dir: Path.join(test_artifact_root, "lemon_skills_tmp")
)

ExUnit.start(exclude: [:integration])

# Isolate HOME so lemon_skills tests don't touch user-level skills/config.
home = Path.join(test_artifact_root, "lemon_skills_home")

File.mkdir_p!(home)
System.put_env("HOME", home)

# Keep X adapter resolution deterministic in tests; individual tests can override.
Application.put_env(:lemon_channels, :x_api_use_secrets, false)

# Load test support modules
Code.require_file("support/http_mock.ex", __DIR__)

# Wire up the deterministic HTTP mock so Discovery tests don't need real HTTP.
Application.put_env(:lemon_skills, :http_client, LemonSkills.HttpClient.Mock)

Application.ensure_all_started(:lemon_skills)

System.at_exit(fn _ ->
  if match?({:ok, ^tmp_target}, File.read_link(tmp_link)) do
    _ = File.rm(tmp_link)
  end
end)
