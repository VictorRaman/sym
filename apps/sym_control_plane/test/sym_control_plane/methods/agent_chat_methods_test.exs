defmodule LemonControlPlane.Methods.AgentChatMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Agent, ChatSend}

  defmodule RunOrchestratorStub do
    def submit(request) do
      if pid = Process.get(:agent_chat_methods_test_pid) do
        send(pid, {:submitted_run_request, request})
      end

      {:ok, "run_agent_method_stub"}
    end
  end

  defmodule AgentChatRouterStub do
    def submit(request) do
      if pid = Process.get(:agent_chat_methods_test_pid) do
        send(pid, {:submitted_chat_request, request})
      end

      {:ok, "run_chat_send_stub"}
    end
  end

  setup do
    previous_orchestrator =
      Application.get_env(:lemon_control_plane, :agent_method_run_orchestrator)

    previous_router = Application.get_env(:lemon_control_plane, :chat_send_router)

    Application.put_env(
      :lemon_control_plane,
      :agent_method_run_orchestrator,
      RunOrchestratorStub
    )

    Application.put_env(:lemon_control_plane, :chat_send_router, AgentChatRouterStub)
    Process.put(:agent_chat_methods_test_pid, self())

    on_exit(fn ->
      case previous_orchestrator do
        nil -> Application.delete_env(:lemon_control_plane, :agent_method_run_orchestrator)
        value -> Application.put_env(:lemon_control_plane, :agent_method_run_orchestrator, value)
      end

      case previous_router do
        nil -> Application.delete_env(:lemon_control_plane, :chat_send_router)
        value -> Application.put_env(:lemon_control_plane, :chat_send_router, value)
      end

      Process.delete(:agent_chat_methods_test_pid)
    end)

    :ok
  end

  test "agent accepts camelCase parameters" do
    assert {:ok, %{"run_id" => "run_agent_method_stub", "session_key" => "agent:default:main"}} =
             Agent.handle(
               %{
                 "prompt" => "hello",
                 "sessionKey" => "agent:default:main",
                 "agentId" => "default",
                 "engineId" => "codex",
                 "queueMode" => "collect",
                 "toolPolicy" => %{"approvals" => %{"bash" => "always"}}
               },
               %{}
             )

    assert_receive {:submitted_run_request, request}, 500
    assert request.session_key == "agent:default:main"
    assert request.agent_id == "default"
    assert request.engine_id == "codex"
    assert request.queue_mode == :collect
    assert request.tool_policy == %{"approvals" => %{"bash" => "always"}}
  end

  test "agent accepts snake_case parameters" do
    assert {:ok, %{"run_id" => "run_agent_method_stub", "session_key" => "agent:snake:main"}} =
             Agent.handle(
               %{
                 "prompt" => "hello",
                 "session_key" => "agent:snake:main",
                 "agent_id" => "snake",
                 "engine_id" => "codex",
                 "queue_mode" => "collect",
                 "tool_policy" => %{"approvals" => %{"bash" => "always"}}
               },
               %{}
             )

    assert_receive {:submitted_run_request, request}, 500
    assert request.session_key == "agent:snake:main"
    assert request.agent_id == "snake"
    assert request.engine_id == "codex"
    assert request.queue_mode == :collect
    assert request.tool_policy == %{"approvals" => %{"bash" => "always"}}
  end

  test "chat.send accepts snake_case session and queue parameters" do
    assert {:ok, %{"runId" => "run_chat_send_stub", "sessionKey" => "agent:chat:main"}} =
             ChatSend.handle(
               %{
                 "session_key" => "agent:chat:main",
                 "prompt" => "chat hello",
                 "agent_id" => "chat-agent",
                 "queue_mode" => "followup"
               },
               %{}
             )

    assert_receive {:submitted_chat_request, request}, 500
    assert request.session_key == "agent:chat:main"
    assert request.agent_id == "chat-agent"
    assert request.queue_mode == :followup
    assert request.prompt == "chat hello"
  end
end
