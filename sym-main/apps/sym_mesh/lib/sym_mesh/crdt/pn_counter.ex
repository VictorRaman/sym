defmodule LemonMesh.Crdt.PNCounter do
  @moduledoc false

  alias LemonMesh.Crdt.GCounter

  @enforce_keys [:increments, :decrements]
  defstruct increments: %GCounter{counts: %{}}, decrements: %GCounter{counts: %{}}

  @type t :: %__MODULE__{
          increments: GCounter.t(),
          decrements: GCounter.t()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{increments: GCounter.new(), decrements: GCounter.new()}

  @spec new(map() | t() | nil) :: t()
  def new(%__MODULE__{} = counter), do: counter
  def new(nil), do: new()

  def new(map) when is_map(map) do
    %__MODULE__{
      increments: GCounter.new(Map.get(map, :increments) || Map.get(map, "increments")),
      decrements: GCounter.new(Map.get(map, :decrements) || Map.get(map, "decrements"))
    }
  end

  @spec increment(t() | map() | nil, String.t(), non_neg_integer()) :: t()
  def increment(counter, node_id, amount)
      when is_binary(node_id) and is_integer(amount) and amount >= 0 do
    normalized = new(counter)
    %{normalized | increments: GCounter.increment(normalized.increments, node_id, amount)}
  end

  @spec decrement(t() | map() | nil, String.t(), non_neg_integer()) :: t()
  def decrement(counter, node_id, amount)
      when is_binary(node_id) and is_integer(amount) and amount >= 0 do
    normalized = new(counter)
    %{normalized | decrements: GCounter.increment(normalized.decrements, node_id, amount)}
  end

  @spec value(t() | map() | nil) :: integer()
  def value(counter) do
    normalized = new(counter)
    GCounter.value(normalized.increments) - GCounter.value(normalized.decrements)
  end

  @spec merge(t() | map() | nil, t() | map() | nil) :: t()
  def merge(left, right) do
    left = new(left)
    right = new(right)

    %__MODULE__{
      increments: GCounter.merge(left.increments, right.increments),
      decrements: GCounter.merge(left.decrements, right.decrements)
    }
  end

  @spec to_map(t() | map() | nil) :: map()
  def to_map(counter) do
    normalized = new(counter)

    %{
      increments: GCounter.to_map(normalized.increments),
      decrements: GCounter.to_map(normalized.decrements)
    }
  end
end
