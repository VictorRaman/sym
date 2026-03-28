defmodule LemonMesh.HandoffDispatcher do
  @moduledoc """
  Orchestrates mesh handoff delivery plus durable bookkeeping.
  """

  require Logger

  alias LemonMesh.HandoffStore
  alias LemonMesh.Replication.Projector

  @type dispatch_result :: %{
          handoff_id: String.t(),
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          selector: atom() | String.t() | nil,
          fanout_count: non_neg_integer(),
          message_id: String.t() | nil,
          handoff_entry_id: String.t() | nil,
          delivery_accepted: boolean(),
          mailbox_persisted: boolean(),
          blackboard_persisted: boolean()
        }

  @spec dispatch(map() | keyword()) ::
          {:ok, dispatch_result()} | {:error, :not_found | {:send_failed, term()} | term()}
  def dispatch(attrs) do
    attrs = normalize_map(attrs)
    mesh_session_id = fetch(attrs, :mesh_session_id)

    with {:ok, _session} <- LemonMesh.get_session(mesh_session_id),
         {:ok, handoff} <-
           HandoffStore.create(%{
             mesh_session_id: mesh_session_id,
             agent_id: fetch(attrs, :agent_id),
             prompt: fetch(attrs, :prompt),
             queue_mode: fetch(attrs, :queue_mode),
             meta: fetch(attrs, :meta, %{}) || %{}
           }),
         {:ok, durable_handoff, envelope} <- persist_mailbox(handoff),
         {:ok, durable_handoff, entry} <- persist_blackboard(durable_handoff) do
      finalize_delivery(attrs, durable_handoff, envelope, entry)
    else
      {:mailbox_failed, failed_handoff, reason} ->
        Logger.warning(
          "Mesh handoff mailbox persistence failed handoff_id=#{failed_handoff.handoff_id} mesh_session_id=#{failed_handoff.mesh_session_id} reason=#{inspect(reason)}"
        )

        {:error, {:mailbox_persist_failed, reason}}

      {:blackboard_failed, failed_handoff, reason} ->
        Logger.warning(
          "Mesh handoff blackboard persistence failed handoff_id=#{failed_handoff.handoff_id} mesh_session_id=#{failed_handoff.mesh_session_id} message_id=#{failed_handoff.message_id} reason=#{inspect(reason)}"
        )

        {:error, {:blackboard_persist_failed, reason}}
    end
  end

  @spec reconcile(HandoffStore.t()) :: {:ok, HandoffStore.t()} | {:error, term()}
  def reconcile(%HandoffStore{delivery_state: delivery_state})
      when delivery_state not in [
             :created,
             :delivery_accepted,
             :mailbox_persisted
           ] do
    {:error, :delivery_not_accepted}
  end

  def reconcile(%HandoffStore{} = handoff) do
    with {:ok, handoff, _envelope} <- persist_mailbox_with_repair(handoff),
         {:ok, handoff, _entry} <- persist_blackboard(handoff) do
      {:ok, handoff}
    else
      {:mailbox_failed, failed_handoff, reason} ->
        log_reconcile_failure(failed_handoff, reason)
        {:error, reason}

      {:blackboard_failed, failed_handoff, reason} ->
        log_reconcile_failure(failed_handoff, reason)
        {:error, reason}
    end
  end

  defp persist_mailbox_with_repair(%HandoffStore{} = handoff) do
    case persist_mailbox(handoff) do
      {:mailbox_failed, failed_handoff, :projection_missing} ->
        case Projector.rebuild_entity("peer_mailbox", failed_handoff.mesh_session_id) do
          {:ok, _messages} -> persist_mailbox(failed_handoff)
          {:error, reason} -> {:mailbox_failed, failed_handoff, reason}
        end

      other ->
        other
    end
  end

  defp send_agent_message(attrs) do
    send_fn = fetch(attrs, :send_fn)

    case send_fn.(fetch(attrs, :agent_id), fetch(attrs, :prompt), fetch(attrs, :send_opts, [])) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp finalize_delivery(attrs, handoff, envelope, entry) do
    case send_agent_message(attrs) do
      {:ok, result} ->
        accepted_handoff =
          case HandoffStore.mark_delivery(handoff.handoff_id,
                 run_id: Map.get(result, :run_id),
                 session_key: Map.get(result, :session_key),
                 delivery_sent_at_ms: System.system_time(:millisecond)
               ) do
            {:ok, updated} ->
              updated

            {:error, reason} ->
              Logger.warning(
                "Mesh handoff delivery bookkeeping failed handoff_id=#{handoff.handoff_id} mesh_session_id=#{handoff.mesh_session_id} reason=#{inspect(reason)}"
              )

              handoff
          end

        {:ok,
         build_result(accepted_handoff, result,
           delivery_accepted: true,
           mailbox_persisted: true,
           blackboard_persisted: true,
           message_id: envelope.message_id,
           handoff_entry_id: entry.entry_id
         )}

      {:error, {:send_failed, reason}} ->
        Logger.warning(
          "Mesh handoff router send failed handoff_id=#{handoff.handoff_id} mesh_session_id=#{handoff.mesh_session_id} message_id=#{envelope.message_id} reason=#{inspect(reason)}"
        )

        {:ok,
         build_result(handoff, %{},
           delivery_accepted: false,
           mailbox_persisted: true,
           blackboard_persisted: true,
           message_id: envelope.message_id,
           handoff_entry_id: entry.entry_id
         )}
    end
  end

  defp persist_mailbox(%HandoffStore{message_id: message_id} = handoff)
       when is_binary(message_id) do
    {:ok, handoff, %{message_id: message_id}}
  end

  defp persist_mailbox(%HandoffStore{} = handoff) do
    attrs = %{
      from_agent: "control_plane",
      to_agent: handoff.agent_id,
      channel: "control_plane_mesh",
      payload_kind: "prompt",
      payload: %{"prompt" => handoff.prompt},
      dedupe_key: handoff.handoff_id,
      metadata:
        handoff.meta
        |> Map.put("queue_mode", handoff.queue_mode)
        |> Map.put("handoff_id", handoff.handoff_id)
        |> Map.put("op_id", handoff.handoff_id)
    }

    case LemonMesh.send_peer_message(handoff.mesh_session_id, attrs) do
      {:ok, envelope} ->
        case HandoffStore.mark_mailbox_persisted(handoff.handoff_id, envelope.message_id) do
          {:ok, updated} -> {:ok, updated, envelope}
          {:error, reason} -> {:mailbox_failed, handoff, reason}
        end

      {:error, reason} ->
        {:mailbox_failed, handoff, reason}
    end
  end

  defp persist_blackboard(%HandoffStore{handoff_entry_id: entry_id} = handoff)
       when is_binary(entry_id) do
    {:ok, handoff, %{entry_id: entry_id}}
  end

  defp persist_blackboard(%HandoffStore{} = handoff) do
    case existing_handoff_entry(handoff.mesh_session_id, handoff.handoff_id) do
      {:ok, entry} ->
        case HandoffStore.mark_blackboard_persisted(handoff.handoff_id, entry.entry_id) do
          {:ok, updated} ->
            finalize_handoff(updated, entry)

          {:error, reason} ->
            {:blackboard_failed, handoff, reason}
        end

      :error ->
        attrs = %{
          entry_id: handoff.handoff_id,
          kind: "handoff",
          author: "control_plane",
          scope: "mesh",
          body: %{
            "handoff_id" => handoff.handoff_id,
            "target_agent" => handoff.agent_id,
            "prompt" => handoff.prompt,
            "run_id" => handoff.run_id,
            "session_key" => handoff.session_key,
            "queue_mode" => handoff.queue_mode
          }
        }

        case LemonMesh.append_blackboard_entry(handoff.mesh_session_id, attrs) do
          {:ok, entry} ->
            case HandoffStore.mark_blackboard_persisted(handoff.handoff_id, entry.entry_id) do
              {:ok, updated} ->
                finalize_handoff(updated, entry)

              {:error, reason} ->
                {:blackboard_failed, handoff, reason}
            end

          {:error, reason} ->
            {:blackboard_failed, handoff, reason}
        end
    end
  end

  defp existing_handoff_entry(mesh_session_id, handoff_id) do
    case LemonMesh.list_blackboard_entries(mesh_session_id) do
      {:ok, entries} ->
        Enum.find_value(entries, :error, fn entry ->
          body = entry.body || %{}

          if entry.kind == "handoff" and
               (body["handoff_id"] || body[:handoff_id]) == handoff_id do
            {:ok, entry}
          end
        end)

      {:error, _reason} ->
        :error
    end
  end

  defp finalize_handoff(handoff, entry) do
    {:ok, handoff, entry}
  end

  defp build_result(handoff, router_result, opts) do
    %{
      handoff_id: handoff.handoff_id,
      run_id: Map.get(router_result, :run_id),
      session_key: Map.get(router_result, :session_key),
      selector: Map.get(router_result, :selector),
      fanout_count: Map.get(router_result, :fanout_count, 0),
      message_id: Keyword.get(opts, :message_id),
      handoff_entry_id: Keyword.get(opts, :handoff_entry_id),
      delivery_accepted: Keyword.fetch!(opts, :delivery_accepted),
      mailbox_persisted: Keyword.fetch!(opts, :mailbox_persisted),
      blackboard_persisted: Keyword.fetch!(opts, :blackboard_persisted)
    }
  end

  defp log_reconcile_failure(%HandoffStore{}, :not_found), do: :ok

  defp log_reconcile_failure(%HandoffStore{} = handoff, reason) do
    Logger.warning(
      "Mesh handoff reconcile failed handoff_id=#{handoff.handoff_id} " <>
        "mesh_session_id=#{handoff.mesh_session_id} message_id=#{handoff.message_id} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp normalize_map(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_map(attrs) when is_map(attrs), do: attrs
  defp normalize_map(_attrs), do: %{}

  defp fetch(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
