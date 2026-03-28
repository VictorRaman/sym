defmodule CodingAgent.Tools.MeshMailboxTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.MeshMailbox
  alias LemonMesh.{SessionSupervisor, Store}

  setup do
    Application.ensure_all_started(:lemon_mesh)
    Store.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  describe "tool/2" do
    test "returns an AgentTool with mesh mailbox metadata" do
      tool = MeshMailbox.tool("/tmp", agent_id: "reviewer")

      assert tool.name == "mesh_mailbox"
      assert tool.label == "Mesh Mailbox"
      assert tool.parameters["required"] == ["action", "mesh_session_id"]
      assert tool.parameters["properties"]["action"]["enum"] == ["list", "ack"]
      assert tool.parameters["properties"]["mesh_session_id"]["type"] == "string"
      assert tool.parameters["properties"]["message_id"]["type"] == "string"
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/5" do
    test "list returns pending messages for the current agent" do
      {:ok, pid} = LemonMesh.start_session(goal: "Mesh mailbox tool list")
      session_id = LemonMesh.session_id(pid)

      {:ok, _reviewer} =
        LemonMesh.send_peer_message(session_id, %{
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          payload_kind: "prompt",
          payload: %{"prompt" => "Review the scheduler changes"}
        })

      {:ok, _implementer} =
        LemonMesh.send_peer_message(session_id, %{
          from_agent: "planner",
          to_agent: "implementer",
          channel: "mesh",
          payload_kind: "fact",
          payload: %{"summary" => "Boundary mapped"}
        })

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: details
             } =
               MeshMailbox.execute(
                 "call_1",
                 %{"action" => "list", "mesh_session_id" => session_id},
                 nil,
                 nil,
                 "reviewer"
               )

      assert text =~ "planner"
      assert details.status == "ok"
      assert details.agent_id == "reviewer"
      assert details.total == 1
      assert length(details.messages) == 1
      assert hd(details.messages).to_agent == "reviewer"
    end

    test "ack marks the message acknowledged for the current agent" do
      {:ok, pid} = LemonMesh.start_session(goal: "Mesh mailbox tool ack")
      session_id = LemonMesh.session_id(pid)

      {:ok, envelope} =
        LemonMesh.send_peer_message(session_id, %{
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          payload_kind: "prompt",
          payload: %{"prompt" => "Review this"}
        })

      assert %AgentToolResult{details: details} =
               MeshMailbox.execute(
                 "call_1",
                 %{
                   "action" => "ack",
                   "mesh_session_id" => session_id,
                   "message_id" => envelope.message_id
                 },
                 nil,
                 nil,
                 "reviewer"
               )

      assert details.status == "ok"
      assert details.message.message_id == envelope.message_id
      assert details.message.acknowledged_by == "reviewer"

      assert {:ok, []} = LemonMesh.list_peer_messages(session_id, to_agent: "reviewer")
    end

    test "agent_id param can override the default current agent" do
      {:ok, pid} = LemonMesh.start_session(goal: "Mesh mailbox override")
      session_id = LemonMesh.session_id(pid)

      {:ok, _envelope} =
        LemonMesh.send_peer_message(session_id, %{
          from_agent: "planner",
          to_agent: "implementer",
          channel: "mesh",
          payload_kind: "prompt",
          payload: %{"prompt" => "Implement this"}
        })

      assert %AgentToolResult{details: details} =
               MeshMailbox.execute(
                 "call_1",
                 %{
                   "action" => "list",
                   "mesh_session_id" => session_id,
                   "agent_id" => "implementer"
                 },
                 nil,
                 nil,
                 "reviewer"
               )

      assert details.agent_id == "implementer"
      assert details.total == 1
    end

    test "ack refuses to acknowledge another agent's message" do
      {:ok, pid} = LemonMesh.start_session(goal: "Mesh mailbox ack guard")
      session_id = LemonMesh.session_id(pid)

      {:ok, envelope} =
        LemonMesh.send_peer_message(session_id, %{
          from_agent: "planner",
          to_agent: "reviewer",
          channel: "mesh",
          payload_kind: "prompt",
          payload: %{"prompt" => "Review this"}
        })

      assert {:error, "message not found for agent"} =
               MeshMailbox.execute(
                 "call_1",
                 %{
                   "action" => "ack",
                   "mesh_session_id" => session_id,
                   "message_id" => envelope.message_id,
                   "agent_id" => "implementer"
                 },
                 nil,
                 nil,
                 "reviewer"
               )
    end
  end
end
