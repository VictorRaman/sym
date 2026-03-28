defmodule LemonMesh.CausalClock do
  @moduledoc """
  BEAM-native vector clock for causal ordering inside Lemon Mesh.
  """

  @enforce_keys [:clock]
  defstruct clock: %{}

  @type order :: :before | :after | :concurrent | :equal

  @type t :: %__MODULE__{
          clock: %{optional(String.t()) => non_neg_integer()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{clock: %{}}

  @spec new(map() | t() | nil) :: t()
  def new(%__MODULE__{} = clock), do: clock
  def new(nil), do: new()

  def new(clock) when is_map(clock) do
    normalized =
      clock
      |> Enum.reduce(%{}, fn
        {node_id, value}, acc when is_integer(value) and value >= 0 ->
          Map.put(acc, to_string(node_id), value)

        {_node_id, _value}, acc ->
          acc
      end)

    %__MODULE__{clock: normalized}
  end

  @spec get(t() | map() | nil, String.t()) :: non_neg_integer()
  def get(clock, node_id) when is_binary(node_id) do
    clock
    |> new()
    |> Map.fetch!(:clock)
    |> Map.get(node_id, 0)
  end

  @spec tick(t() | map() | nil, String.t()) :: t()
  def tick(clock, node_id) when is_binary(node_id) do
    normalized = new(clock)

    %__MODULE__{
      clock: Map.update(normalized.clock, node_id, 1, &(&1 + 1))
    }
  end

  @spec merge(t() | map() | nil, t() | map() | nil) :: t()
  def merge(left, right) do
    left = new(left)
    right = new(right)

    merged =
      Map.merge(left.clock, right.clock, fn _node_id, left_value, right_value ->
        max(left_value, right_value)
      end)

    %__MODULE__{clock: merged}
  end

  @spec compare(t() | map() | nil, t() | map() | nil) :: order()
  def compare(left, right) do
    left = new(left)
    right = new(right)

    node_ids =
      left.clock
      |> Map.keys()
      |> Enum.concat(Map.keys(right.clock))
      |> Enum.uniq()

    {left_less, right_less} =
      Enum.reduce(node_ids, {false, false}, fn node_id, {left_less, right_less} ->
        left_value = Map.get(left.clock, node_id, 0)
        right_value = Map.get(right.clock, node_id, 0)

        {
          left_less or left_value < right_value,
          right_less or left_value > right_value
        }
      end)

    case {left_less, right_less} do
      {false, false} -> :equal
      {true, false} -> :before
      {false, true} -> :after
      {true, true} -> :concurrent
    end
  end

  @spec node_count(t() | map() | nil) :: non_neg_integer()
  def node_count(clock) do
    clock
    |> new()
    |> Map.fetch!(:clock)
    |> map_size()
  end

  @spec to_map(t() | map() | nil) :: map()
  def to_map(clock) do
    clock
    |> new()
    |> Map.fetch!(:clock)
  end
end
