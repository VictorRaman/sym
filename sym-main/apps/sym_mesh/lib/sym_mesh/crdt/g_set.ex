defmodule LemonMesh.Crdt.GSet do
  @moduledoc false

  @enforce_keys [:items]
  defstruct items: MapSet.new()

  @type t :: %__MODULE__{
          items: MapSet.t(String.t())
        }

  @spec new() :: t()
  def new, do: %__MODULE__{items: MapSet.new()}

  @spec new(t() | [term()] | MapSet.t() | nil) :: t()
  def new(%__MODULE__{} = set), do: set
  def new(nil), do: new()
  def new(%MapSet{} = items), do: %__MODULE__{items: normalize_items(items)}
  def new(items) when is_list(items), do: %__MODULE__{items: normalize_items(items)}

  @spec insert(t() | [term()] | MapSet.t() | nil, term()) :: t()
  def insert(set, item) do
    normalized = new(set)
    %{normalized | items: MapSet.put(normalized.items, normalize_item(item))}
  end

  @spec contains?(t() | [term()] | MapSet.t() | nil, String.t()) :: boolean()
  def contains?(set, item) when is_binary(item) do
    set
    |> new()
    |> Map.fetch!(:items)
    |> MapSet.member?(item)
  end

  @spec len(t() | [term()] | MapSet.t() | nil) :: non_neg_integer()
  def len(set) do
    set
    |> new()
    |> Map.fetch!(:items)
    |> MapSet.size()
  end

  @spec empty?(t() | [term()] | MapSet.t() | nil) :: boolean()
  def empty?(set), do: len(set) == 0

  @spec merge(t() | [term()] | MapSet.t() | nil, t() | [term()] | MapSet.t() | nil) :: t()
  def merge(left, right) do
    left = new(left)
    right = new(right)
    %{left | items: MapSet.union(left.items, right.items)}
  end

  @spec to_list(t() | [term()] | MapSet.t() | nil) :: [String.t()]
  def to_list(set) do
    set
    |> new()
    |> Map.fetch!(:items)
    |> Enum.sort()
  end

  defp normalize_items(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> MapSet.new()
  end

  defp normalize_item(item), do: to_string(item)
end
