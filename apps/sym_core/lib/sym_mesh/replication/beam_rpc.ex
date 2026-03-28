defmodule LemonMesh.Replication.BeamRpc do
  @moduledoc false

  alias LemonMesh.{CausalClock, NodeIdentity, OpLog}
  alias LemonMesh.Replication.{Snapshot, Watermark}

  @spec get_snapshot(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_snapshot(peer_id, scope, opts \\ []) when is_binary(peer_id) and is_binary(scope) do
    requester_id = Keyword.get(opts, :requester_id, NodeIdentity.current_node_id())
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    rpc_call(peer_id, :get_snapshot_for, [requester_id, scope], timeout_ms)
  end

  @spec pull_ops(String.t(), map(), pos_integer(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def pull_ops(peer_id, after_watermark, limit, opts \\ [])
      when is_binary(peer_id) and is_map(after_watermark) and is_integer(limit) and limit > 0 do
    requester_id = Keyword.get(opts, :requester_id, NodeIdentity.current_node_id())
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    rpc_call(peer_id, :pull_ops_for, [requester_id, after_watermark, limit], timeout_ms)
  end

  @spec get_snapshot_for(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_snapshot_for(requester_peer_id, scope)
      when is_binary(requester_peer_id) and is_binary(scope) do
    with {:ok, snapshot} <- Snapshot.current(scope),
         :ok <- Watermark.set_outbound(requester_peer_id, snapshot["watermark"]) do
      {:ok, snapshot}
    end
  end

  @spec pull_ops_for(String.t(), map(), pos_integer()) :: {:ok, [term()]} | {:error, term()}
  def pull_ops_for(requester_peer_id, after_watermark, limit)
      when is_binary(requester_peer_id) and is_map(after_watermark) and is_integer(limit) and
             limit > 0 do
    ops =
      OpLog.list()
      |> Enum.filter(&newer_than_watermark?(&1, after_watermark))
      |> Enum.take(limit)

    outbound_watermark =
      Enum.reduce(ops, after_watermark, fn op, acc ->
        CausalClock.merge(acc, op.causal_clock) |> CausalClock.to_map()
      end)

    :ok = Watermark.set_outbound(requester_peer_id, outbound_watermark)
    {:ok, ops}
  end

  defp rpc_call(peer_id, function_name, args, timeout_ms) do
    peer_node = String.to_atom(peer_id)
    :rpc.call(peer_node, __MODULE__, function_name, args, timeout_ms)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp newer_than_watermark?(op, after_watermark) do
    current = Map.get(after_watermark, op.origin_node_id, 0)
    Map.get(op.causal_clock || %{}, op.origin_node_id, 0) > current
  end
end
