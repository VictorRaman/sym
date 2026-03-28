defmodule LemonMesh.HandoffReconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonMesh.{HandoffDispatcher, HandoffStore}

  @default_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms =
      opts
      |> Keyword.get(:interval_ms, Application.get_env(:lemon_mesh, :handoff_reconcile_interval_ms, @default_interval_ms))
      |> normalize_interval()

    state = %{interval_ms: interval_ms}
    schedule_tick(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile_tick, state) do
    for handoff <- HandoffStore.list_reconcilable() do
      case HandoffDispatcher.reconcile(handoff) do
        {:ok, _updated} ->
          emit_reconcile_event(handoff, :ok)
          :ok

        {:error, :not_found} ->
          emit_reconcile_event(handoff, :error)
          :ok

        {:error, reason} ->
          emit_reconcile_event(handoff, :error)

          Logger.warning(
            "Mesh handoff reconcile failed handoff_id=#{handoff.handoff_id} " <>
              "mesh_session_id=#{handoff.mesh_session_id} message_id=#{handoff.message_id} " <>
              "reason=#{inspect(reason)}"
          )
      end
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :reconcile_tick, interval_ms)
  end

  defp emit_reconcile_event(handoff, result) do
    :telemetry.execute(
      [:lemon_mesh, :handoff, :reconcile],
      %{count: 1},
      %{
        result: result,
        handoff_id: handoff.handoff_id,
        mesh_session_id: handoff.mesh_session_id,
        message_id: handoff.message_id
      }
    )
  end

  defp normalize_interval(interval_ms) when is_integer(interval_ms) and interval_ms > 0, do: interval_ms
  defp normalize_interval(_interval_ms), do: @default_interval_ms
end
