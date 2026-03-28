defmodule CodingAgent.ToolExecutorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.{ToolExecutor, ToolPolicy}

  describe "wrap_with_approval/3" do
    test "returns tool unchanged when not in require_approval list" do
      tool = %AgentTool{
        name: "read",
        description: "Read a file",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      policy = ToolPolicy.from_profile(:full_access)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

      # Should be the same tool (unchanged)
      assert wrapped.name == tool.name
      assert wrapped.execute == tool.execute
    end

    test "wraps tool when in require_approval list" do
      tool = %AgentTool{
        name: "write",
        description: "Write a file",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      policy = ToolPolicy.from_profile(:subagent_restricted)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

      # The execute function should be different (wrapped)
      assert wrapped.name == tool.name
      assert wrapped.execute != tool.execute
    end
  end

  describe "wrap_all_with_approval/3" do
    test "wraps only tools that require approval" do
      read_tool = %AgentTool{
        name: "read",
        description: "Read a file",
        execute: fn _, _, _, _ -> :read_result end
      }

      write_tool = %AgentTool{
        name: "write",
        description: "Write a file",
        execute: fn _, _, _, _ -> :write_result end
      }

      edit_tool = %AgentTool{
        name: "edit",
        description: "Edit a file",
        execute: fn _, _, _, _ -> :edit_result end
      }

      tools = [read_tool, write_tool, edit_tool]
      policy = ToolPolicy.from_profile(:subagent_restricted)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_all_with_approval(tools, policy, context)

      # Read should be unchanged
      read_wrapped = Enum.find(wrapped, &(&1.name == "read"))
      assert read_wrapped.execute == read_tool.execute

      # Write and edit should be wrapped (different execute function)
      write_wrapped = Enum.find(wrapped, &(&1.name == "write"))
      assert write_wrapped.execute != write_tool.execute

      edit_wrapped = Enum.find(wrapped, &(&1.name == "edit"))
      assert edit_wrapped.execute != edit_tool.execute
    end
  end

  describe "execute_with_approval/4" do
    setup do
      # Keep the approvals policy table clean between tests.
      CodingAgent.TestStore.reset()

      :ok
    end

    test "executes function when pre-approved globally" do
      session_key = "agent:test-global:main"
      executed = :erlang.make_ref()
      action = %{command: "ls"}

      # Hash the action the same way ApprovalsBridge does
      action_hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(action))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      # Pre-approve the tool globally (using hashed action key)
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      context = %{
        run_id: "test-run",
        session_key: session_key,
        timeout_ms: 100
      }

      result =
        ToolExecutor.execute_with_approval(
          "bash",
          action,
          fn ->
            %AgentToolResult{
              content: [%TextContent{type: :text, text: "executed #{inspect(executed)}"}]
            }
          end,
          context
        )

      # The result should contain our expected text
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, inspect(executed))

      # Cleanup
      LemonCore.Store.delete(:exec_approvals_policy, {"bash", action_hash})
    end

    test "does not log when approval is granted" do
      session_key = "agent:test-granted:main"
      action = %{command: "pwd"}

      action_hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(action))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      context = %{
        run_id: "test-run-granted",
        session_key: session_key,
        timeout_ms: 100
      }

      {result, log} =
        capture_log([level: :debug], fn ->
          result =
            ToolExecutor.execute_with_approval(
              "bash",
              action,
              fn ->
                %AgentToolResult{
                  content: [%TextContent{type: :text, text: "executed"}]
                }
              end,
              context
            )

          send(self(), {:approval_granted_result, result})
        end)
        |> then(fn log ->
          receive do
            {:approval_granted_result, result} -> {result, log}
          end
        end)

      assert %AgentToolResult{content: [%TextContent{text: "executed"}]} = result
      refute log =~ "approved at scope"

      LemonCore.Store.delete(:exec_approvals_policy, {"bash", action_hash})
    end

    test "does not log when approval is denied" do
      context = %{
        run_id: "test-denied",
        session_key: "agent:denied:main",
        timeout_ms: 100,
        approval_request_fun: fn _ -> {:ok, :denied} end
      }

      {result, log} =
        capture_log([level: :debug], fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
              end,
              context
            )

          send(self(), {:approval_denied_result, result})
        end)
        |> then(fn log ->
          receive do
            {:approval_denied_result, result} -> {result, log}
          end
        end)

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{reason: :approval_denied, denied: true}
             } = result

      assert String.contains?(text, "execution was denied")
      refute log =~ "denied by approval"
    end

    test "returns timeout result when approval times out" do
      context = %{
        run_id: "test-timeout",
        session_key: "agent:timeout:main",
        timeout_ms: 10
      }

      {result, log} =
        capture_log(fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
              end,
              context
            )

          send(self(), {:approval_timeout_result, result})
        end)
        |> then(fn log ->
          receive do
            {:approval_timeout_result, result} -> {result, log}
          end
        end)

      # Should get a timeout result
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, "timed out waiting for approval")
      assert log =~ "approval timed out"
    end

    test "returns error result when approval returns non-timeout error" do
      parent = self()

      context = %{
        run_id: "test-approval-error",
        session_key: "agent:error:main",
        timeout_ms: 100,
        approval_request_fun: fn _ ->
          {:error, :service_unavailable}
        end
      }

      {result, log} =
        capture_log(fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                send(parent, :executed)
                %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
              end,
              context
            )

          send(self(), {:approval_error_result, result})
        end)
        |> then(fn log ->
          receive do
            {:approval_error_result, result} -> {result, log}
          end
        end)

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{reason: :approval_error, approval_error: :service_unavailable}
             } = result

      assert String.contains?(text, "approval failed")
      assert log =~ "approval failed"
      refute_received :executed
    end

    test "legacy local paths still auto-approve when approval service raises" do
      parent = self()

      context = %{
        run_id: "test-local-auto-approve",
        session_key: "agent:local:main",
        timeout_ms: 100,
        approval_request_fun: fn _ ->
          send(parent, :approval_requested)
          raise "approval bridge unavailable"
        end
      }

      {result, log} =
        capture_log(fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                send(parent, :executed)
                %AgentToolResult{content: [%TextContent{type: :text, text: "executed"}]}
              end,
              context
            )

          send(self(), {:local_auto_approve_result, result})
        end)
        |> then(fn log ->
          receive do
            {:local_auto_approve_result, result} -> {result, log}
          end
        end)

      assert_received :approval_requested
      assert_received :executed
      assert %AgentToolResult{content: [%TextContent{text: "executed"}]} = result
      assert log =~ "auto-approving dangerous_tool"
    end

    test "trusted cluster paths fail closed when approval service raises and forward node context" do
      parent = self()

      context = %{
        run_id: "test-cluster-fail-closed",
        session_key: "agent:cluster:main",
        agent_id: "reviewer",
        node_id: "peer-a@host",
        lease_epoch: 7,
        trusted_cluster: true,
        cluster_internal: true,
        timeout_ms: 100,
        approval_request_fun: fn request ->
          send(parent, {:approval_request, request})
          raise "approval bridge unavailable"
        end
      }

      {result, log} =
        capture_log(fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                send(parent, :executed)
                %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
              end,
              context
            )

          send(self(), {:cluster_fail_closed_result, result})
        end)
        |> then(fn log ->
          receive do
            {:cluster_fail_closed_result, result} -> {result, log}
          end
        end)

      assert_received {:approval_request, request}
      assert request.node_id == "peer-a@host"
      assert request.agent_id == "reviewer"
      assert request.session_key == "agent:cluster:main"

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{reason: :approval_error}
             } = result

      assert String.contains?(text, "approval failed")
      assert log =~ "approval failed"
      refute_received :executed
    end

    test "trusted cluster paths reject stale worktree leases before requesting approval" do
      parent = self()

      context = %{
        run_id: "test-cluster-stale-lease",
        session_key: "agent:cluster:main",
        agent_id: "reviewer",
        node_id: "peer-a@host",
        lease_epoch: 6,
        trusted_cluster: true,
        cluster_internal: true,
        worktree_slice_key: "repo:alpha",
        worktree_lease_reader: fn "repo:alpha" ->
          {:ok,
           %LemonMesh.WorktreeLease{
             agent_id: "reviewer",
             worktree_path: "/tmp/worktree-a",
             lease_epoch: 7,
             origin_node_id: "peer-a@host",
             expires_at_ms: System.system_time(:millisecond) + 5_000
           }}
        end,
        approval_request_fun: fn _request ->
          send(parent, :approval_requested)
          {:ok, :approved, :node}
        end
      }

      {result, log} =
        capture_log(fn ->
          result =
            ToolExecutor.execute_with_approval(
              "dangerous_tool",
              %{action: "delete"},
              fn ->
                send(parent, :executed)
                %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
              end,
              context
            )

          send(self(), {:stale_lease_result, result})
        end)
        |> then(fn log ->
          receive do
            {:stale_lease_result, result} -> {result, log}
          end
        end)

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{reason: :approval_error}
             } = result

      assert String.contains?(text, "approval failed")
      assert log =~ "stale_cluster_lease"
      refute_received :approval_requested
      refute_received :executed
    end
  end

  describe "policy integration" do
    test "subagent_restricted policy requires approval for write and edit" do
      policy = ToolPolicy.from_profile(:subagent_restricted)

      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "read")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "full_access policy requires no approvals" do
      policy = ToolPolicy.from_profile(:full_access)

      refute ToolPolicy.requires_approval?(policy, "write")
      refute ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "custom policy can require approval for any tool" do
      policy = ToolPolicy.custom(require_approval: ["bash", "write", "delete"])

      assert ToolPolicy.requires_approval?(policy, "bash")
      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "delete")
      refute ToolPolicy.requires_approval?(policy, "read")
    end
  end
end
