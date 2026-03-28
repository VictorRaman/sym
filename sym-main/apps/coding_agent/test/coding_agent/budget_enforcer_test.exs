defmodule CodingAgent.BudgetEnforcerTest do
  @moduledoc """
  Tests for the BudgetEnforcer module.

  BudgetEnforcer provides budget enforcement hooks for the agent lifecycle.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.{BudgetEnforcer, BudgetTracker, RunGraph}

  setup do
    RunGraph.clear()
    :ok
  end

  # ============================================================================
  # check_api_call/2 Tests
  # ============================================================================

  describe "check_api_call/2" do
    test "returns :ok when no budget exists" do
      run_id = "run_#{System.unique_integer([:positive])}"
      assert :ok = BudgetEnforcer.check_api_call(run_id, estimated_tokens: 1000)
    end
  end

  describe "on_run_start/2" do
    test "does not log when initializing budget successfully" do
      run_id = "run_#{System.unique_integer([:positive])}"

      log =
        capture_log([level: :debug], fn ->
          assert :ok = BudgetEnforcer.on_run_start(run_id, [])
        end)

      refute log =~ "Initialized budget for run"
    end
  end

  # ============================================================================
  # check_subagent_spawn/2 Tests
  # ============================================================================

  describe "check_subagent_spawn/2" do
    test "returns :ok when under child limit" do
      parent_id = "parent_#{System.unique_integer([:positive])}"
      RunGraph.new_run(%{id: parent_id, type: :test})
      BudgetTracker.store_budget(parent_id, BudgetTracker.create_budget(max_children: 3))

      assert :ok = BudgetEnforcer.check_subagent_spawn(parent_id, [])
    end
  end

  # ============================================================================
  # on_api_response/2 Tests
  # ============================================================================

  describe "on_api_response/2" do
    test "returns :ok after recording response" do
      run_id = "run_#{System.unique_integer([:positive])}"
      RunGraph.new_run(%{id: run_id, type: :test})
      BudgetTracker.store_budget(run_id, BudgetTracker.create_budget([]))

      response = %{usage: %{total_tokens: 50, cost: 0.25}}

      assert :ok = BudgetEnforcer.on_api_response(run_id, response)
    end
  end

  # ============================================================================
  # handle_budget_exceeded/3 Tests
  # ============================================================================

  describe "handle_budget_exceeded/3" do
    test "returns error tuple by default" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      {{:error, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert is_binary(message)
      assert log =~ "Budget exceeded"
    end

    test "returns cancel tuple when action is :cancel" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      {{:cancel, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :cancel)
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert is_binary(message)
      assert log =~ "Budget exceeded"
    end

    test "returns compact tuple when action is :compact" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      {{:compact, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :compact)
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert is_binary(message)
      assert log =~ "Budget exceeded"
    end
  end

  # ============================================================================
  # budget_summary/1 Tests
  # ============================================================================

  describe "budget_summary/1" do
    test "returns no_budget when budget doesn't exist" do
      run_id = "run_#{System.unique_integer([:positive])}"

      summary = BudgetEnforcer.budget_summary(run_id)

      assert summary.status == :no_budget
    end
  end

  # ============================================================================
  # Error Message Formatting Tests
  # ============================================================================

  describe "error message formatting" do
    test "formats token limit exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 1000, limit: 500}

      {{:error, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert message =~ "Token budget exceeded"
      assert log =~ "Budget exceeded"
    end

    test "formats cost limit exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :cost_limit_exceeded, used: 10.0, limit: 5.0}

      {{:error, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert message =~ "Cost budget exceeded"
      assert log =~ "Budget exceeded"
    end

    test "formats max children exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :max_children_exceeded, active: 5, limit: 3}

      {{:error, message}, log} =
        capture_log(fn ->
          result = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
          send(self(), {:budget_result, result})
        end)
        |> then(fn log ->
          receive do
            {:budget_result, result} -> {result, log}
          end
        end)

      assert message =~ "Maximum concurrent subagents reached"
      assert log =~ "Budget exceeded"
    end
  end
end
