defmodule CodingAgent.RuntimeMailboxJournal do
  @moduledoc """
  Durable acceptance journal for mesh mailbox runtime prompts.

  An entry means a session durably accepted a mailbox envelope. Entries remain
  pending until the corresponding runtime user message is persisted and saved.
  """

  require Logger

  alias LemonCore.Store
  alias LemonMesh.{CausalClock, NodeIdentity}

  @table :coding_agent_runtime_mailbox_journal

  @type queue_mode :: :followup | :collect | :steer | :steer_backlog | :interrupt

  @type t :: %__MODULE__{
          session_id: String.t(),
          mesh_session_id: String.t() | nil,
          agent_id: String.t(),
          envelope_id: String.t(),
          op_id: String.t(),
          text: String.t(),
          queue_mode: queue_mode(),
          accepted_clock: map(),
          accepted_at_ms: non_neg_integer(),
          applied_clock: map() | nil,
          applied_at_ms: non_neg_integer() | nil
        }

  defstruct [
    :session_id,
    :mesh_session_id,
    :agent_id,
    :envelope_id,
    :op_id,
    :text,
    :queue_mode,
    :accepted_clock,
    :accepted_at_ms,
    :applied_clock,
    :applied_at_ms
  ]

  @spec record_acceptance(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def record_acceptance(attrs) do
    attrs = normalize_map(attrs)
    session_id = fetch!(attrs, :session_id)
    envelope_id = fetch!(attrs, :envelope_id)

    entry = new(attrs)

    Store.update(@table, key(session_id, envelope_id), fn
      nil ->
        {:ok, to_map(entry), {:ok, entry}}

      current when is_map(current) ->
        case decode_entry(current, key(session_id, envelope_id), rewrite_on_error: false) do
          {:ok, decoded} ->
            {:reply, {:ok, decoded}}

          {:error, :invalid_entry} ->
            {:ok, to_map(entry), {:ok, entry}}
        end
    end)
  end

  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(session_id, envelope_id) when is_binary(session_id) and is_binary(envelope_id) do
    case Store.get(@table, key(session_id, envelope_id)) do
      nil -> {:error, :not_found}
      payload when is_map(payload) -> decode_entry(payload, key(session_id, envelope_id))
    end
  end

  @spec delete_entry(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_entry(session_id, envelope_id)
      when is_binary(session_id) and is_binary(envelope_id) do
    Store.delete(@table, key(session_id, envelope_id))
  end

  @spec mark_applied(String.t(), String.t(), non_neg_integer() | nil, map() | nil) ::
          :ok | {:error, term()}
  def mark_applied(session_id, envelope_id, applied_at_ms \\ nil, applied_clock \\ nil)
      when is_binary(session_id) and is_binary(envelope_id) do
    at_ms = applied_at_ms || System.system_time(:millisecond)

    Store.update(@table, key(session_id, envelope_id), fn
      nil ->
        {:error, :not_found}

      current when is_map(current) ->
        next =
          current
          |> from_map()
          |> Map.put(:applied_at_ms, at_ms)
          |> Map.put(:applied_clock, normalize_applied_clock(applied_clock, current))

        {:ok, to_map(next), :ok}
    end)
  end

  @spec pending_entries(String.t()) :: [t()]
  def pending_entries(session_id) when is_binary(session_id) do
    @table
    |> Store.list()
    |> Enum.reduce([], fn {stored_key, payload}, acc ->
      case decode_entry(payload, stored_key) do
        {:ok, entry} -> [entry | acc]
        {:error, :invalid_entry} -> acc
      end
    end)
    |> Enum.filter(fn entry ->
      entry.session_id == session_id and is_nil(entry.applied_at_ms)
    end)
    |> Enum.sort_by(&{&1.accepted_at_ms, &1.envelope_id}, :asc)
  end

  @spec pending_count(String.t()) :: non_neg_integer()
  def pending_count(session_id) when is_binary(session_id) do
    session_id
    |> pending_entries()
    |> length()
  end

  @spec reset() :: :ok
  def reset do
    for {stored_key, _value} <- Store.list(@table) do
      Store.delete(@table, stored_key)
    end

    :ok
  end

  @spec message_ref(Ai.Types.UserMessage.t()) :: {String.t(), non_neg_integer()} | nil
  def message_ref(%Ai.Types.UserMessage{content: content, timestamp: timestamp})
      when is_binary(content) and is_integer(timestamp) do
    {content, timestamp}
  end

  def message_ref(_message), do: nil

  @spec message_ref(String.t(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  def message_ref(text, accepted_at_ms)
      when is_binary(text) and is_integer(accepted_at_ms) and accepted_at_ms >= 0 do
    {text, accepted_at_ms}
  end

  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = normalize_map(attrs)
    envelope_id = fetch!(attrs, :envelope_id)

    %__MODULE__{
      session_id: fetch!(attrs, :session_id),
      mesh_session_id: fetch(attrs, :mesh_session_id),
      agent_id: fetch!(attrs, :agent_id),
      envelope_id: envelope_id,
      op_id: fetch(attrs, :op_id, envelope_id),
      text: fetch!(attrs, :text),
      queue_mode: normalize_queue_mode(fetch(attrs, :queue_mode)),
      accepted_clock: normalize_clock(fetch(attrs, :accepted_clock, %{})),
      accepted_at_ms: fetch(attrs, :accepted_at_ms, System.system_time(:millisecond)),
      applied_clock: normalize_optional_clock(fetch(attrs, :applied_clock)),
      applied_at_ms: fetch(attrs, :applied_at_ms)
    }
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs = normalize_map(map)
    envelope_id = fetch!(attrs, :envelope_id)

    %__MODULE__{
      session_id: fetch!(attrs, :session_id),
      mesh_session_id: fetch(attrs, :mesh_session_id),
      # Legacy rows created before `agent_id` was introduced must still replay.
      agent_id: fetch_binary(attrs, :agent_id, ""),
      envelope_id: envelope_id,
      op_id: fetch(attrs, :op_id, envelope_id),
      text: fetch!(attrs, :text),
      queue_mode: normalize_queue_mode(fetch(attrs, :queue_mode)),
      accepted_clock: normalize_clock(fetch(attrs, :accepted_clock, %{})),
      accepted_at_ms: fetch(attrs, :accepted_at_ms, System.system_time(:millisecond)),
      applied_clock: normalize_optional_clock(fetch(attrs, :applied_clock)),
      applied_at_ms: fetch(attrs, :applied_at_ms)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      session_id: entry.session_id,
      mesh_session_id: entry.mesh_session_id,
      agent_id: entry.agent_id,
      envelope_id: entry.envelope_id,
      op_id: entry.op_id,
      text: entry.text,
      queue_mode: entry.queue_mode,
      accepted_clock: entry.accepted_clock,
      accepted_at_ms: entry.accepted_at_ms,
      applied_clock: entry.applied_clock,
      applied_at_ms: entry.applied_at_ms
    }
  end

  defp key(session_id, envelope_id), do: {session_id, envelope_id}

  defp normalize_queue_mode(:collect), do: :collect
  defp normalize_queue_mode(:steer), do: :steer
  defp normalize_queue_mode(:steer_backlog), do: :steer_backlog
  defp normalize_queue_mode(:interrupt), do: :interrupt
  defp normalize_queue_mode("collect"), do: :collect
  defp normalize_queue_mode("steer"), do: :steer
  defp normalize_queue_mode("steer_backlog"), do: :steer_backlog
  defp normalize_queue_mode("interrupt"), do: :interrupt
  defp normalize_queue_mode(_other), do: :followup

  defp normalize_clock(clock), do: clock |> CausalClock.new() |> CausalClock.to_map()

  defp normalize_optional_clock(nil), do: nil
  defp normalize_optional_clock(clock), do: normalize_clock(clock)

  defp normalize_applied_clock(nil, current) do
    current
    |> from_map()
    |> Map.fetch!(:accepted_clock)
    |> CausalClock.tick(NodeIdentity.current_node_id())
    |> CausalClock.to_map()
  end

  defp normalize_applied_clock(clock, _current), do: normalize_clock(clock)

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

  defp fetch!(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) and value != "" ->
        value

      value when is_integer(value) ->
        value

      value ->
        raise ArgumentError,
              "missing runtime mailbox journal field #{inspect(key)}: #{inspect(value)}"
    end
  end

  defp fetch_binary(attrs, key, default) do
    case fetch(attrs, key, default) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp decode_entry(payload, stored_key, opts \\ []) when is_map(payload) do
    {:ok, from_map(payload)}
  rescue
    error in ArgumentError ->
      Logger.warning(
        "dropping malformed runtime mailbox journal entry key=#{inspect(stored_key)} reason=#{Exception.message(error)}"
      )

      if Keyword.get(opts, :rewrite_on_error, true) do
        _ = Store.delete(@table, stored_key)
      end

      {:error, :invalid_entry}
  end
end
