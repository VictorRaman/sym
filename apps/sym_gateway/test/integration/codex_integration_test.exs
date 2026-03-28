defmodule LemonGateway.CodexIntegrationTest do
  use ExUnit.Case

  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.Types.CompletedEvent

  @tag :integration
  test "codex runner completes" do
    cond do
      not enabled?("LEMON_CODEX_INTEGRATION") ->
        :ok

      System.find_executable("codex") == nil ->
        :ok

      true ->
        tmp_dir =
          Path.join(
            System.tmp_dir!(),
            "gateway_codex_integration_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(tmp_dir)

        on_exit(fn ->
          File.rm_rf!(tmp_dir)
        end)

        case hermetic_env(tmp_dir) do
          {:ok, env} ->
            {:ok, pid} =
              CodexRunner.start_link(
                prompt: "Reply with OK.",
                cwd: File.cwd!(),
                env: env,
                timeout: 180_000
              )

            stream = CodexRunner.stream(pid)

            task =
              Task.async(fn ->
                AgentCore.EventStream.events(stream) |> Enum.to_list()
              end)

            events = Task.await(task, 200_000)

            assert Enum.any?(events, fn
                     {:cli_event, %CompletedEvent{ok: true}} -> true
                     _ -> false
                   end)

          {:skip, _reason} ->
            :ok
        end
    end
  end

  defp hermetic_env(tmp_dir) do
    host_auth = Path.join(System.user_home!(), ".codex/auth.json")

    if not File.exists?(host_auth) do
      {:skip, "codex auth.json not available for hermetic gateway integration"}
    else
      home_dir = Path.join(tmp_dir, "home")
      codex_home = Path.join(home_dir, ".codex")
      cache_home = Path.join(home_dir, ".cache")

      File.mkdir_p!(Path.join(codex_home, "memories"))
      File.mkdir_p!(Path.join(codex_home, "skills"))
      File.mkdir_p!(Path.join(codex_home, "sessions"))
      File.mkdir_p!(Path.join(codex_home, "tmp"))
      File.mkdir_p!(cache_home)
      File.cp!(host_auth, Path.join(codex_home, "auth.json"))
      File.write!(Path.join(codex_home, "config.toml"), "")

      {:ok,
       [
         {"HOME", home_dir},
         {"CODEX_HOME", codex_home},
         {"XDG_CACHE_HOME", cache_home}
       ]}
    end
  end

  defp enabled?(env) do
    System.get_env(env) in ["1", "true", "TRUE", "yes", "YES"]
  end
end
