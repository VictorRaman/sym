defmodule CodingAgent.Session.Persistence do
  @moduledoc false

  require Logger

  alias CodingAgent.RuntimeMailboxJournal
  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.Session

  @spec persist_message(map(), term()) :: map()
  def persist_message(state, message) do
    new_session_manager =
      case message do
        %Ai.Types.UserMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        %Ai.Types.AssistantMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        %Ai.Types.ToolResultMessage{} ->
          SessionManager.append_message(
            state.session_manager,
            MessageSerialization.serialize_message(message)
          )

        _ ->
          state.session_manager
      end

    state
    |> Map.put(:session_manager, new_session_manager)
    |> maybe_finalize_runtime_journal(message)
  end

  @spec restore_messages_from_session(Session.t()) :: [map()]
  def restore_messages_from_session(session) do
    context = SessionManager.build_session_context(session)

    context.messages
    |> Enum.map(&MessageSerialization.deserialize_message/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec maybe_register_session(Session.t(), String.t(), boolean(), atom()) :: :ok
  def maybe_register_session(_session_manager, _cwd, false, _registry), do: :ok

  def maybe_register_session(session_manager, cwd, true, registry) do
    if Process.whereis(registry) do
      case Registry.register(registry, session_manager.header.id, %{cwd: cwd}) do
        {:ok, _} ->
          :ok

        {:error, {:already_registered, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register session: #{inspect(reason)}")
      end
    end
  end

  @spec maybe_unregister_session(String.t(), boolean(), atom()) :: :ok
  def maybe_unregister_session(_session_id, false, _registry), do: :ok

  def maybe_unregister_session(session_id, true, registry) do
    if Process.whereis(registry) do
      Registry.unregister(registry, session_id)
    end

    :ok
  end

  @spec save(map()) :: {:ok, map()} | {:error, term(), map()}
  def save(state) do
    path =
      state.session_file ||
        Path.join(
          SessionManager.get_session_dir(state.cwd),
          "#{state.session_manager.header.id}.jsonl"
        )

    case SessionManager.save_to_file(path, state.session_manager) do
      :ok ->
        {:ok, %{state | session_file: path}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp maybe_finalize_runtime_journal(state, %Ai.Types.UserMessage{} = message) do
    case matched_runtime_journal_entry(state, message) do
      nil ->
        state

      envelope_id ->
        case save(state) do
          {:ok, saved_state} ->
            case RuntimeMailboxJournal.mark_applied(
                   saved_state.session_manager.header.id,
                   envelope_id,
                   message.timestamp
                 ) do
              :ok ->
                maybe_mark_handoff_runtime_applied(message)
                remove_runtime_journal_ref(saved_state, envelope_id)

              {:error, reason} ->
                Logger.warning(
                  "Failed to mark runtime mailbox journal entry applied envelope_id=#{envelope_id} reason=#{inspect(reason)}"
                )

                saved_state
            end

          {:error, reason, failed_state} ->
            Logger.warning(
              "Failed to save runtime mailbox journal-backed message envelope_id=#{envelope_id} reason=#{inspect(reason)}"
            )

            failed_state
        end
    end
  end

  defp maybe_finalize_runtime_journal(state, _message), do: state

  defp matched_runtime_journal_entry(state, message) do
    refs = Map.get(state, :mesh_mailbox_journal_pending_refs, %{}) || %{}

    matched_runtime_journal_entry_from_metadata(message, refs) ||
      matched_runtime_journal_entry_from_message_ref(message, refs)
  end

  defp matched_runtime_journal_entry_from_metadata(message, refs) do
    metadata = normalize_metadata(Map.get(message, :metadata))
    envelope_id = metadata_value(metadata, "envelope_id")
    op_id = metadata_value(metadata, "op_id")

    cond do
      is_binary(envelope_id) and envelope_id != "" and Map.has_key?(refs, envelope_id) ->
        envelope_id

      is_binary(op_id) and op_id != "" ->
        Enum.find_value(refs, fn {stored_envelope_id, pending_ref} ->
          if pending_ref_op_id(pending_ref) == op_id, do: stored_envelope_id, else: nil
        end)

      true ->
        nil
    end
  end

  defp matched_runtime_journal_entry_from_message_ref(message, refs) do
    message_ref = RuntimeMailboxJournal.message_ref(message)

    Enum.find_value(refs, fn {envelope_id, pending_ref} ->
      ref =
        case pending_ref do
          %{message_ref: stored_ref} -> stored_ref
          stored_ref -> stored_ref
        end

      if ref == message_ref, do: envelope_id, else: nil
    end)
  end

  defp remove_runtime_journal_ref(state, envelope_id) do
    refs =
      state
      |> Map.get(:mesh_mailbox_journal_pending_refs, %{})
      |> Kernel.||(%{})
      |> Map.delete(envelope_id)

    %{state | mesh_mailbox_journal_pending_refs: refs}
  end

  defp maybe_mark_handoff_runtime_applied(%Ai.Types.UserMessage{} = message) do
    metadata = normalize_metadata(Map.get(message, :metadata))

    case metadata_value(metadata, "handoff_id") do
      handoff_id when is_binary(handoff_id) and handoff_id != "" ->
        case LemonMesh.HandoffStore.mark_runtime_applied(handoff_id, message.timestamp) do
          {:ok, _handoff} ->
            _ = LemonMesh.HandoffStore.mark_completed(handoff_id, message.timestamp)
            :ok

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to mark handoff runtime applied handoff_id=#{handoff_id} reason=#{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp metadata_value(metadata, key) when is_binary(key) do
    case key do
      "envelope_id" -> Map.get(metadata, "envelope_id") || Map.get(metadata, :envelope_id)
      "op_id" -> Map.get(metadata, "op_id") || Map.get(metadata, :op_id)
      "handoff_id" -> Map.get(metadata, "handoff_id") || Map.get(metadata, :handoff_id)
      _ -> Map.get(metadata, key)
    end
  end

  defp pending_ref_op_id(%{op_id: op_id}) when is_binary(op_id), do: op_id
  defp pending_ref_op_id(%{"op_id" => op_id}) when is_binary(op_id), do: op_id
  defp pending_ref_op_id(_pending_ref), do: nil
end
