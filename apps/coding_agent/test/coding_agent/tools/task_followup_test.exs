defmodule CodingAgent.Tools.Task.FollowupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.Task.Followup

  test "does not log when auto-followup is skipped without a parent session key" do
    outcome =
      {:ok,
       %AgentToolResult{
         content: [%TextContent{type: :text, text: "completed"}]
       }}

    log =
      capture_log([level: :debug], fn ->
        assert :ok =
                 Followup.maybe_send_async_followup(
                   %{auto_followup: true, description: "background task"},
                   "task-123",
                   "run-123",
                   outcome
                 )
      end)

    refute log =~ "Task tool skipping auto-followup"
  end
end
