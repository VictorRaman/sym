defmodule LemonControlPlane.MeshMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    MeshBlackboardAppend,
    MeshBlackboardGet,
    MeshSessionGet,
    MeshSessionList,
    MeshSessionStart
  }

  alias LemonControlPlane.Methods.Registry
  alias LemonMesh.{SessionSupervisor, Store}

  setup do
    Application.ensure_all_started(:lemon_mesh)
    ensure_registry_started()

    Store.reset()

    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    Process.sleep(20)
    :ok
  end

  test "mesh.session.start creates a session and mesh.session.get reads it" do
    assert {:ok, started} =
             MeshSessionStart.handle(
               %{
                 "goal" => "Coordinate planner and reviewer",
                 "roles" => [%{"id" => "planner"}, %{"id" => "reviewer"}],
                 "memoryScopes" => ["facts", "decisions"]
               },
               %{}
             )

    assert is_binary(started["sessionId"])
    assert started["goal"] == "Coordinate planner and reviewer"
    assert started["status"] == "active"

    assert {:ok, fetched} =
             MeshSessionGet.handle(%{"sessionId" => started["sessionId"]}, %{})

    assert fetched["sessionId"] == started["sessionId"]
    assert fetched["goal"] == started["goal"]
    assert length(fetched["roles"]) == 2
  end

  test "mesh.session.list includes created sessions" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Listed mesh session"}, %{})

    assert {:ok, payload} = MeshSessionList.handle(%{}, %{})

    assert Enum.any?(payload["sessions"], fn session ->
             session["sessionId"] == started["sessionId"] and session["goal"] == "Listed mesh session"
           end)
  end

  test "mesh.blackboard.append and mesh.blackboard.get round-trip entries" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Blackboard methods"}, %{})

    assert {:ok, append_payload} =
             MeshBlackboardAppend.handle(
               %{
                 "sessionId" => started["sessionId"],
                 "kind" => "fact",
                 "author" => "researcher",
                 "body" => %{"path" => "lib/router.ex", "note" => "main entry"}
               },
               %{}
             )

    assert append_payload["entry"]["kind"] == "fact"
    assert append_payload["entry"]["author"] == "researcher"

    assert {:ok, get_payload} =
             MeshBlackboardGet.handle(
               %{"sessionId" => started["sessionId"], "kind" => "fact"},
               %{}
             )

    assert get_payload["sessionId"] == started["sessionId"]
    assert [
             %{
               "entryId" => _,
               "kind" => "fact",
               "author" => "researcher"
             }
           ] = get_payload["entries"]
  end

  test "mesh.blackboard.append works for a stopped persisted session" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Stopped blackboard methods"}, %{})
    assert {:ok, pid} = LemonMesh.session_pid(started["sessionId"])
    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    assert {:ok, append_payload} =
             MeshBlackboardAppend.handle(
               %{
                 "sessionId" => started["sessionId"],
                 "kind" => "handoff",
                 "author" => "control_plane",
                 "body" => %{"note" => "persisted append"}
               },
               %{}
             )

    assert append_payload["entry"]["kind"] == "handoff"

    assert {:ok, get_payload} =
             MeshBlackboardGet.handle(%{"sessionId" => started["sessionId"]}, %{})

    assert get_payload["total"] == 1
  end

  test "mesh.agent.mailbox.list returns pending messages for the requested agent" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox list methods"}, %{})

    assert {:ok, reviewer_message} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review the scheduler changes"}
             })

    assert {:ok, _other_message} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "implementer",
               channel: "mesh",
               payload_kind: "fact",
               payload: %{"summary" => "Boundary mapped"}
             })

    assert {:ok, payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.list",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer"
               },
               ctx_with_scopes([:read])
             )

    assert payload["meshSessionId"] == started["sessionId"]
    assert payload["total"] == 1

    assert [
             %{
               "messageId" => message_id,
               "fromAgent" => "planner",
               "toAgent" => "reviewer",
               "channel" => "mesh",
               "payloadKind" => "prompt",
               "payload" => %{"prompt" => "Review the scheduler changes"},
               "acknowledgedAtMs" => nil,
               "acknowledgedBy" => nil
             }
           ] = payload["messages"]

    assert message_id == reviewer_message.message_id
  end

  test "mesh.agent.mailbox.ack acknowledges a message and hides it from pending queries" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox ack methods"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "implementer",
               channel: "mesh",
               payload_kind: "fact",
               payload: %{"summary" => "Scheduler boundary identified"}
             })

    assert {:ok, payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.ack",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "implementer",
                 "messageId" => envelope.message_id
               },
               ctx_with_scopes([:write])
             )

    assert payload["meshSessionId"] == started["sessionId"]

    assert %{
             "messageId" => message_id,
             "toAgent" => "implementer",
             "acknowledgedBy" => "implementer",
             "acknowledgedAtMs" => acknowledged_at_ms
           } = payload["message"]

    assert message_id == envelope.message_id
    assert is_integer(acknowledged_at_ms)

    assert {:ok, pending_payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.list",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "implementer"
               },
               ctx_with_scopes([:read])
             )

    assert pending_payload["messages"] == []
    assert pending_payload["total"] == 0

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               started["sessionId"],
               to_agent: "implementer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_by == "implementer"
  end

  test "mesh.agent.mailbox.ack can require the expected claimant" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox ack claimant guard"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review this"}
             })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               started["sessionId"],
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert {:error, {:not_found, "Mesh mailbox message not found"}} =
             Registry.dispatch(
               "mesh.agent.mailbox.ack",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer",
                 "messageId" => envelope.message_id,
                 "expectedClaimedBy" => "session:other"
               },
               ctx_with_scopes([:write])
             )

    assert {:ok, [stored]} =
             LemonMesh.list_peer_messages(
               started["sessionId"],
               to_agent: "reviewer",
               pending_only: false
             )

    assert stored.message_id == envelope.message_id
    assert stored.acknowledged_at_ms == nil
    assert stored.claimed_by == "session:reviewer"
  end

  test "mesh.agent.mailbox.list and ack work for a stopped persisted session" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Stopped mailbox methods"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "control_plane",
               to_agent: "reviewer",
               channel: "control_plane_mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review persisted mailbox message"}
             })

    assert {:ok, pid} = LemonMesh.session_pid(started["sessionId"])
    assert :ok = SessionSupervisor.stop_session(pid)
    Process.sleep(20)

    assert {:ok, list_payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.list",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer"
               },
               ctx_with_scopes([:read])
             )

    assert list_payload["total"] == 1
    assert hd(list_payload["messages"])["messageId"] == envelope.message_id

    assert {:ok, ack_payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.ack",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer",
                 "messageId" => envelope.message_id
               },
               ctx_with_scopes([:write])
             )

    assert ack_payload["message"]["messageId"] == envelope.message_id
    assert ack_payload["message"]["acknowledgedBy"] == "reviewer"
  end

  test "mesh.agent.mailbox.ack does not acknowledge another agent's message" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox ack guard"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review this"}
             })

    assert {:error, {:not_found, "Mesh mailbox message not found"}} =
             Registry.dispatch(
               "mesh.agent.mailbox.ack",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "implementer",
                 "messageId" => envelope.message_id
               },
               ctx_with_scopes([:write])
             )

    assert {:ok, [pending]} =
             LemonMesh.list_peer_messages(started["sessionId"], to_agent: "reviewer")

    assert pending.message_id == envelope.message_id
    assert pending.acknowledged_at_ms == nil
  end

  test "mesh.agent.mailbox.list includes claim fields for leased messages" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox claim fields"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review with lease"}
             })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               started["sessionId"],
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert {:ok, payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.list",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer",
                 "includeClaimed" => true
               },
               ctx_with_scopes([:read])
             )

    assert payload["total"] == 1

    assert [
             %{
               "messageId" => message_id,
               "claimedBy" => "session:reviewer",
               "claimedAtMs" => claimed_at_ms,
               "claimExpiresAtMs" => claim_expires_at_ms
             }
           ] = payload["messages"]

    assert message_id == envelope.message_id
    assert is_integer(claimed_at_ms)
    assert is_integer(claim_expires_at_ms)
  end

  test "mesh.agent.mailbox.list includeClaimed does not return acknowledged history" do
    assert {:ok, started} = MeshSessionStart.handle(%{"goal" => "Mailbox include claimed pending only"}, %{})

    assert {:ok, envelope} =
             LemonMesh.send_peer_message(started["sessionId"], %{
               from_agent: "planner",
               to_agent: "reviewer",
               channel: "mesh",
               payload_kind: "prompt",
               payload: %{"prompt" => "Review then ack"}
             })

    assert {:ok, [_claimed]} =
             LemonMesh.claim_peer_messages(
               started["sessionId"],
               to_agent: "reviewer",
               claimed_by: "session:reviewer",
               lease_ms: 500
             )

    assert {:ok, _acknowledged} =
             LemonMesh.ack_peer_message(
               started["sessionId"],
               envelope.message_id,
               acknowledged_by: "reviewer",
               expected_to_agent: "reviewer",
               expected_claimed_by: "session:reviewer"
             )

    assert {:ok, payload} =
             Registry.dispatch(
               "mesh.agent.mailbox.list",
               %{
                 "meshSessionId" => started["sessionId"],
                 "agentId" => "reviewer",
                 "includeClaimed" => true
               },
               ctx_with_scopes([:read])
             )

    assert payload["total"] == 0
    assert payload["messages"] == []
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end
  end

  defp ctx_with_scopes(scopes) do
    %{
      conn_id: "mesh-methods-test-conn",
      conn_pid: self(),
      auth: %{
        role: :operator,
        scopes: scopes,
        token: nil,
        client_id: nil,
        identity: nil
      }
    }
  end
end
