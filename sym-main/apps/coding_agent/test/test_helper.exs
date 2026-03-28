test_artifact_root =
  System.get_env("LEMON_TEST_ARTIFACT_ROOT") ||
    Path.join(System.tmp_dir!(), "lemon_test_artifacts_#{System.unique_integer([:positive])}")

tmp_target = Path.join(test_artifact_root, "coding_agent_tmp")
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
  exclude: [:integration],
  capture_log: true,
  tmp_dir: Path.join(test_artifact_root, "coding_agent_tmp")
)

ExUnit.start()

# Use a test-local store backend so coding_agent tests don't depend on lemon_gateway.
Code.require_file("support/test_store.ex", __DIR__)
Application.put_env(:lemon_core, :store_mod, CodingAgent.TestStore)

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Isolate HOME to avoid leaking user-level config (CLAUDE.md, config.toml, extensions)
original_home = System.get_env("HOME")
original_agent_dir_env = System.get_env("LEMON_AGENT_DIR")
original_coding_agent_agent_dir = Application.get_env(:coding_agent, :agent_dir)
original_lemon_skills_agent_dir = Application.get_env(:lemon_skills, :agent_dir)

home = Path.join(test_artifact_root, "coding_agent_home")
agent_dir = Path.join(test_artifact_root, "agent")

File.mkdir_p!(home)
File.mkdir_p!(agent_dir)
System.put_env("HOME", home)
System.put_env("LEMON_AGENT_DIR", agent_dir)
Application.put_env(:coding_agent, :agent_dir, agent_dir)
Application.put_env(:lemon_skills, :agent_dir, agent_dir)

# Keep rustup/cargo toolchain paths stable after HOME isolation so tests that call
# cargo via rustup shims can still resolve installed toolchains and targets.
if original_home do
  if is_nil(System.get_env("RUSTUP_HOME")) do
    System.put_env("RUSTUP_HOME", Path.join(original_home, ".rustup"))
  end

  if is_nil(System.get_env("CARGO_HOME")) do
    System.put_env("CARGO_HOME", Path.join(original_home, ".cargo"))
  end
end

# Ensure agent directories exist under the isolated HOME
CodingAgent.Config.ensure_dirs!()

# Skills are now managed by lemon_skills (registry + installer).
_ = Application.stop(:lemon_skills)
Application.ensure_all_started(:lemon_skills)

# Compile test support files
Code.require_file("support/mock_ui.ex", __DIR__)
Code.require_file("support/permission_helpers.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)

# Load shared test support from agent_core app
agent_core_support = Path.join([__DIR__, "..", "..", "agent_core", "test", "support", "mocks.ex"])

if File.exists?(agent_core_support) do
  Code.require_file(agent_core_support)
end

# Load shared test support from ai app (for integration tests)
ai_support = Path.join([__DIR__, "..", "..", "ai", "test", "support", "integration_config.ex"])

if File.exists?(ai_support) do
  Code.require_file(ai_support)
end

ExUnit.after_suite(fn _ ->
  if original_home do
    System.put_env("HOME", original_home)
  else
    System.delete_env("HOME")
  end

  if original_agent_dir_env do
    System.put_env("LEMON_AGENT_DIR", original_agent_dir_env)
  else
    System.delete_env("LEMON_AGENT_DIR")
  end

  if is_nil(original_coding_agent_agent_dir) do
    Application.delete_env(:coding_agent, :agent_dir)
  else
    Application.put_env(:coding_agent, :agent_dir, original_coding_agent_agent_dir)
  end

  if is_nil(original_lemon_skills_agent_dir) do
    Application.delete_env(:lemon_skills, :agent_dir)
  else
    Application.put_env(:lemon_skills, :agent_dir, original_lemon_skills_agent_dir)
  end

  _ = Application.stop(:lemon_skills)
  Application.ensure_all_started(:lemon_skills)
end)

System.at_exit(fn _ ->
  if match?({:ok, ^tmp_target}, File.read_link(tmp_link)) do
    _ = File.rm(tmp_link)
  end
end)
