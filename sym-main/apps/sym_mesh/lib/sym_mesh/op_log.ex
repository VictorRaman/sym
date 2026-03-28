defmodule LemonMesh.OpLog do
  @moduledoc false

  alias LemonCore.Store
  alias LemonMesh.{CausalClock, NodeIdentity, Op}

  @table :mesh_op_log

  @spec append(map() | keyword()) :: {:ok, Op.t()} | {:error, term()}
  def append(attrs) do
    attrs = normalize_map(attrs)
    op = build_op(attrs)

    case Store.get(@table, op.op_id) do
      payload when is_map(payload) ->
        {:ok, Op.from_map(payload)}

      nil ->
        case Store.put(@table, op.op_id, Op.to_map(op)) do
          :ok -> {:ok, op}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec get(String.t()) :: {:ok, Op.t()} | {:error, :not_found}
  def get(op_id) when is_binary(op_id) do
    case Store.get(@table, op_id) do
      nil -> {:error, :not_found}
      payload when is_map(payload) -> {:ok, Op.from_map(payload)}
    end
  end

  @spec list(keyword()) :: [Op.t()]
  def list(opts \\ []) do
    entity_type = Keyword.get(opts, :entity_type)
    entity_id = Keyword.get(opts, :entity_id)
    origin_node_id = Keyword.get(opts, :origin_node_id)

    @table
    |> Store.list()
    |> Enum.map(fn {_op_id, payload} -> Op.from_map(payload) end)
    |> maybe_filter(:entity_type, entity_type)
    |> maybe_filter(:entity_id, entity_id)
    |> maybe_filter(:origin_node_id, origin_node_id)
    |> Enum.sort_by(&sort_key/1, :asc)
  end

  @spec reset() :: :ok
  def reset do
    for {stored_key, _value} <- Store.list(@table) do
      Store.delete(@table, stored_key)
    end

    :ok
  end

  defp build_op(attrs) do
    entity_type = fetch_required_string!(attrs, :entity_type)
    entity_id = fetch_required_string!(attrs, :entity_id)
    origin_node_id = fetch(attrs, :origin_node_id, NodeIdentity.current_node_id())
    provided_clock = fetch(attrs, :causal_clock)

    causal_clock =
      cond do
        is_map(provided_clock) ->
          provided_clock

        true ->
          list(entity_type: entity_type, entity_id: entity_id)
          |> Enum.reduce(CausalClock.new(), fn op, acc ->
            CausalClock.merge(acc, op.causal_clock)
          end)
          |> CausalClock.tick(origin_node_id)
          |> CausalClock.to_map()
      end

    attrs
    |> Map.put(:entity_type, entity_type)
    |> Map.put(:entity_id, entity_id)
    |> Map.put(:origin_node_id, origin_node_id)
    |> Map.put(:causal_clock, causal_clock)
    |> Op.new()
  end

  defp maybe_filter(items, _field, nil), do: items

  defp maybe_filter(items, field, expected) do
    Enum.filter(items, fn item -> Map.get(item, field) == expected end)
  end

  defp sort_key(op) do
    {
      op.recorded_at_ms,
      Map.get(op.causal_clock || %{}, op.origin_node_id, 0),
      op.op_id
    }
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

  defp fetch_required_string!(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "missing op-log field #{inspect(key)}: #{inspect(value)}"
    end
  end
end
