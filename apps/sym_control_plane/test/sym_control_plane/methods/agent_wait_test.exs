defmodule LemonControlPlane.Methods.AgentWaitTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.AgentWait
  alias LemonCore.{Bus, Event, Store}

  setup do
    run_id = "run_agent_wait_test_#{System.unique_integer([:positive])}"
    topic = "run:#{run_id}"

    on_exit(fn ->
      Bus.unsubscribe(topic)
      Store.delete(:runs, run_id)
    end)

    {:ok, run_id: run_id, topic: topic}
  end

  test "returns immediately when the run is already finalized in RunStore", %{run_id: run_id} do
    completed = completed_summary(run_id, answer: "stored-answer")
    Store.put(:runs, run_id, %{events: [], summary: %{completed: completed}, started_at: now_ms()})

    assert {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 50}, %{})
    assert result["runId"] == run_id
    assert result["ok"] == true
    assert result["answer"] == "stored-answer"
  end

  test "returns when a run_completed bus event arrives", %{run_id: run_id, topic: topic} do
    completed = completed_summary(run_id, answer: "from-event")

    Task.start(fn ->
      Process.sleep(20)
      Bus.broadcast(topic, Event.new(:run_completed, %{completed: completed}))
    end)

    assert {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 200}, %{})
    assert result["runId"] == run_id
    assert result["ok"] == true
    assert result["answer"] == "from-event"
  end

  test "returns when completion appears in RunStore after the wait starts even without a bus event", %{
    run_id: run_id
  } do
    completed = completed_summary(run_id, answer: "late-store")

    Task.start(fn ->
      Process.sleep(20)

      Store.put(:runs, run_id, %{
        events: [],
        summary: %{completed: completed},
        started_at: now_ms()
      })
    end)

    assert {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 200}, %{})
    assert result["runId"] == run_id
    assert result["ok"] == true
    assert result["answer"] == "late-store"
  end

  test "times out cleanly when neither event nor store completion appears", %{run_id: run_id} do
    assert {:error, {:timeout, "Run did not complete within timeout", ^run_id}} =
             AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 30}, %{})
  end

  defp completed_summary(run_id, opts) do
    %{
      run_id: run_id,
      ok: Keyword.get(opts, :ok, true),
      answer: Keyword.get(opts, :answer, ""),
      error: Keyword.get(opts, :error, nil)
    }
  end

  defp now_ms, do: System.system_time(:millisecond)
end
