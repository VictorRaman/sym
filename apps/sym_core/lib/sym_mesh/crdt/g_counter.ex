defmodule LemonMesh.Crdt.GCounter do
  @moduledoc false

  @enforce_keys [:counts]
  defstruct counts: %{}

  @type t :: %__MODULE__{
          counts: %{optional(String.t()) => non_neg_integer()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{counts: %{}}

  @spec new(map() | t() | nil) :: t()
  def new(%__MODULE__{} = counter), do: counter
  def new(nil), do: new()

  def new(counts) when is_map(counts) do
    normalized =
      counts
      |> Enum.reduce(%{}, fn
        {node_id, value}, acc when is_integer(value) and value >= 0 ->
          Map.put(acc, to_string(node_id), value)

        {_node_id, _value}, acc ->
          acc
      end)

    %__MODULE__{counts: normalized}
  end

  @spec increment(t() | map() | nil, String.t(), non_neg_integer()) :: t()
  def increment(counter, node_id, amount)
      when is_binary(node_id) and is_integer(amount) and amount >= 0 do
    normalized = new(counter)

    %__MODULE__{
      counts: Map.update(normalized.counts, node_id, amount, &(&1 + amount))
    }
  end

  @spec value(t() | map() | nil) :: non_neg_integer()
  def value(counter) do
    counter
    |> new()
    |> Map.fetch!(:counts)
    |> Map.values()
    |> Enum.sum()
  end

  @spec merge(t() | map() | nil, t() | map() | nil) :: t()
  def merge(left, right) do
    left = new(left)
    right = new(right)

    merged =
      Map.merge(left.counts, right.counts, fn _node_id, left_value, right_value ->
        max(left_value, right_value)
      end)

    %__MODULE__{counts: merged}
  end

  @spec to_map(t() | map() | nil) :: map()
  def to_map(counter) do
    counter
    |> new()
    |> Map.fetch!(:counts)
  end
end
