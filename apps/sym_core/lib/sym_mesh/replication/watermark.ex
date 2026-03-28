defmodule LemonMesh.Replication.Watermark do
  @moduledoc false

  alias LemonCore.Store
  alias LemonMesh.{CausalClock, Op}

  @table :mesh_replication_watermarks
  @local_scope :local

  @spec local() :: map()
  def local, do: get(@local_scope)

  @spec inbound(String.t()) :: map()
  def inbound(peer_id) when is_binary(peer_id), do: get({:inbound, peer_id})

  @spec outbound(String.t()) :: map()
  def outbound(peer_id) when is_binary(peer_id), do: get({:outbound, peer_id})

  @spec get(term()) :: map()
  def get(scope) do
    case Store.get(@table, scope) do
      value when is_map(value) -> CausalClock.to_map(value)
      _ -> %{}
    end
  end

  @spec advance_local(Op.t() | map() | CausalClock.t()) :: {:ok, map()} | {:error, term()}
  def advance_local(clock_or_op), do: advance(@local_scope, clock_or_op)

  @spec advance_inbound(String.t(), Op.t() | map() | CausalClock.t()) ::
          {:ok, map()} | {:error, term()}
  def advance_inbound(peer_id, clock_or_op) when is_binary(peer_id) do
    advance({:inbound, peer_id}, clock_or_op)
  end

  @spec advance_outbound(String.t(), Op.t() | map() | CausalClock.t()) ::
          {:ok, map()} | {:error, term()}
  def advance_outbound(peer_id, clock_or_op) when is_binary(peer_id) do
    advance({:outbound, peer_id}, clock_or_op)
  end

  @spec set_inbound(String.t(), map()) :: :ok | {:error, term()}
  def set_inbound(peer_id, clock) when is_binary(peer_id) and is_map(clock) do
    Store.put(@table, {:inbound, peer_id}, CausalClock.to_map(clock))
  end

  @spec set_outbound(String.t(), map()) :: :ok | {:error, term()}
  def set_outbound(peer_id, clock) when is_binary(peer_id) and is_map(clock) do
    Store.put(@table, {:outbound, peer_id}, CausalClock.to_map(clock))
  end

  @spec list_inbound() :: map()
  def list_inbound do
    list_by_prefix(:inbound)
  end

  @spec list_outbound() :: map()
  def list_outbound do
    list_by_prefix(:outbound)
  end

  @spec advance(term(), Op.t() | map() | CausalClock.t()) :: {:ok, map()} | {:error, term()}
  def advance(scope, clock_or_op) do
    incoming_clock = extract_clock(clock_or_op)

    Store.update(@table, scope, fn current ->
      merged =
        current
        |> CausalClock.merge(incoming_clock)
        |> CausalClock.to_map()

      {:ok, merged, {:ok, merged}}
    end)
  end

  @spec reset() :: :ok
  def reset do
    for {stored_key, _value} <- Store.list(@table) do
      Store.delete(@table, stored_key)
    end

    :ok
  end

  defp list_by_prefix(prefix) do
    Store.list(@table)
    |> Enum.reduce(%{}, fn
      {{^prefix, peer_id}, value}, acc when is_binary(peer_id) and is_map(value) ->
        Map.put(acc, peer_id, CausalClock.to_map(value))

      _other, acc ->
        acc
    end)
  end

  defp extract_clock(%Op{causal_clock: causal_clock}), do: CausalClock.to_map(causal_clock)
  defp extract_clock(clock), do: CausalClock.to_map(clock)
end
