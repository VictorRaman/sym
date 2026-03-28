defmodule CodingAgent.Session.MeshMailboxRuntime do
  @moduledoc false

  require Logger

  alias CodingAgent.{RuntimeMailboxJournal, Session}
  alias LemonMesh.{CausalClock, NodeIdentity}

  @spec schedule_next(map(), non_neg_integer() | nil) :: map()
  def schedule_next(state, delay_ms \\ nil)

  def schedule_next(%{mesh_session_id: nil} = state, _delay_ms) do
    %{state | mesh_mailbox_tick_ref: nil}
  end

  def schedule_next(state, delay_ms) do
    if state.mesh_mailbox_tick_ref do
      _ = Process.cancel_timer(state.mesh_mailbox_tick_ref)
    end

    next_delay_ms = normalize_delay(delay_ms || state.mesh_mailbox_poll_interval_ms)
    ref = Process.send_after(self(), :mesh_mailbox_tick, next_delay_ms)
    %{state | mesh_mailbox_tick_ref: ref}
  end

  @spec handle_tick(map()) :: map()
  def handle_tick(state) do
    state = %{state | mesh_mailbox_tick_ref: nil}

    cond do
      not active_mesh_runtime?(state) ->
        state

      state.is_streaming ->
        schedule_next(state)

      true ->
        case replay_pending(state) do
          {:ok, replayed_state, replayed_count} when replayed_count > 0 ->
            schedule_next(replayed_state, 0)

          {:ok, replayed_state, 0} ->
            case claim_next_message(replayed_state) do
              {:ok, nil} ->
                schedule_next(replayed_state)

              {:ok, envelope} ->
                case inject_message(replayed_state, envelope) do
                  {:ok, next_state} ->
                    schedule_next(next_state, 0)

                  {:error, reason} ->
                    Logger.warning(
                      "Mesh mailbox runtime failed to inject envelope #{envelope.message_id}: #{inspect(reason)}"
                    )

                    schedule_next(replayed_state)
                end

              {:error, :not_found} ->
                schedule_next(replayed_state)

              {:error, reason} ->
                Logger.warning("Mesh mailbox runtime failed to claim message: #{inspect(reason)}")
                schedule_next(replayed_state)
            end

          {:error, reason} ->
            Logger.warning(
              "Mesh mailbox runtime failed to replay journal entries: #{inspect(reason)}"
            )

            schedule_next(state)
        end
    end
  end

  @spec replay_pending_entries(map()) :: map()
  def replay_pending_entries(state) do
    case replay_pending(state) do
      {:ok, next_state, _count} -> next_state
      {:error, _reason} -> state
    end
  end

  defp active_mesh_runtime?(state) do
    is_binary(state.mesh_session_id) and state.mesh_session_id != "" and
      is_binary(state.agent_id) and state.agent_id != ""
  end

  defp claim_next_message(state) do
    claimed_by = claimant_id(state)

    case LemonMesh.claim_peer_messages(
           state.mesh_session_id,
           to_agent: state.agent_id,
           claimed_by: claimed_by,
           lease_ms: state.mesh_mailbox_lease_ms,
           limit: 1,
           payload_kind: "prompt"
         ) do
      {:ok, [envelope | _]} -> {:ok, envelope}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inject_message(state, envelope) do
    accepted_at_ms = System.system_time(:millisecond)
    queue_mode = queue_mode(envelope)

    with {:ok, text} <- runtime_text(envelope),
         accepted_clock <- acceptance_clock(envelope),
         {:ok, entry} <-
           RuntimeMailboxJournal.record_acceptance(%{
             session_id: state.session_manager.header.id,
             mesh_session_id: state.mesh_session_id,
             agent_id: state.agent_id,
             envelope_id: envelope.message_id,
             op_id: journal_op_id(envelope),
             text: text,
             queue_mode: queue_mode,
             accepted_clock: accepted_clock,
             accepted_at_ms: accepted_at_ms
           }) do
      maybe_mark_handoff_runtime_accepted(envelope, accepted_at_ms)

      case LemonMesh.ack_peer_message(
             state.mesh_session_id,
             envelope.message_id,
             acknowledged_by: state.agent_id,
             expected_to_agent: state.agent_id,
             expected_claimed_by: claimant_id(state)
           ) do
        {:ok, _acknowledged} ->
          Session.inject_runtime_message(
            state,
            text,
            queue_mode,
            journal_envelope_id: envelope.message_id,
            journal_op_id: entry.op_id,
            accepted_at_ms: entry.accepted_at_ms,
            journal_source: "mesh_mailbox",
            journal_handoff_id: handoff_id(envelope),
            journal_accepted_clock: entry.accepted_clock,
            journal_lease_epoch: envelope.lease_epoch
          )

        {:error, reason} ->
          _ =
            RuntimeMailboxJournal.delete_entry(
              state.session_manager.header.id,
              envelope.message_id
            )

          {:error, reason}
      end
    end
  end

  defp replay_pending(state) do
    entry =
      state.session_manager.header.id
      |> RuntimeMailboxJournal.pending_entries()
      |> Enum.reject(fn entry ->
        Map.has_key?(state.mesh_mailbox_journal_pending_refs || %{}, entry.envelope_id)
      end)
      |> List.first()

    case entry do
      nil ->
        {:ok, state, 0}

      entry ->
        case Session.inject_runtime_message(
               state,
               entry.text,
               entry.queue_mode,
               journal_envelope_id: entry.envelope_id,
               journal_op_id: entry.op_id,
               accepted_at_ms: entry.accepted_at_ms,
               journal_source: "mesh_mailbox",
               journal_handoff_id: entry.op_id,
               journal_accepted_clock: entry.accepted_clock
             ) do
          {:ok, next_state} ->
            {:ok, next_state, 1}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp runtime_text(envelope) do
    prompt =
      case envelope.payload do
        %{"prompt" => value} when is_binary(value) and value != "" -> value
        %{prompt: value} when is_binary(value) and value != "" -> value
        _ -> nil
      end

    if is_binary(prompt) do
      source = envelope.from_agent || "unknown"
      {:ok, "[mesh message from #{source}] #{prompt}"}
    else
      {:error, :invalid_prompt_payload}
    end
  end

  defp queue_mode(envelope) do
    metadata = envelope.metadata || %{}

    case Map.get(metadata, "queue_mode") || Map.get(metadata, :queue_mode) do
      "collect" -> :collect
      "steer" -> :steer
      "interrupt" -> :interrupt
      "steer_backlog" -> :steer_backlog
      :collect -> :collect
      :steer -> :steer
      :interrupt -> :interrupt
      :steer_backlog -> :steer_backlog
      _ -> :followup
    end
  end

  defp claimant_id(state) do
    "session:" <> state.session_manager.header.id
  end

  defp journal_op_id(envelope) do
    metadata = envelope.metadata || %{}

    cond do
      is_binary(Map.get(metadata, "op_id")) and Map.get(metadata, "op_id") != "" ->
        Map.get(metadata, "op_id")

      is_binary(Map.get(metadata, :op_id)) and Map.get(metadata, :op_id) != "" ->
        Map.get(metadata, :op_id)

      is_binary(Map.get(metadata, "handoff_id")) and Map.get(metadata, "handoff_id") != "" ->
        Map.get(metadata, "handoff_id")

      is_binary(Map.get(metadata, :handoff_id)) and Map.get(metadata, :handoff_id) != "" ->
        Map.get(metadata, :handoff_id)

      true ->
        envelope.message_id
    end
  end

  defp acceptance_clock(envelope) do
    envelope.vector_clock
    |> CausalClock.new()
    |> CausalClock.tick(NodeIdentity.current_node_id())
    |> CausalClock.to_map()
  end

  defp handoff_id(envelope) do
    metadata = envelope.metadata || %{}

    cond do
      is_binary(Map.get(metadata, "handoff_id")) and Map.get(metadata, "handoff_id") != "" ->
        Map.get(metadata, "handoff_id")

      is_binary(Map.get(metadata, :handoff_id)) and Map.get(metadata, :handoff_id) != "" ->
        Map.get(metadata, :handoff_id)

      true ->
        nil
    end
  end

  defp maybe_mark_handoff_runtime_accepted(envelope, accepted_at_ms) do
    case handoff_id(envelope) do
      handoff_id when is_binary(handoff_id) and handoff_id != "" ->
        case LemonMesh.HandoffStore.mark_runtime_accepted(handoff_id, accepted_at_ms) do
          {:ok, _handoff} ->
            :ok

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to mark handoff runtime accepted handoff_id=#{handoff_id} reason=#{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end
  end

  defp normalize_delay(delay_ms) when is_integer(delay_ms) and delay_ms >= 0, do: delay_ms
  defp normalize_delay(_delay_ms), do: 2_000
end
