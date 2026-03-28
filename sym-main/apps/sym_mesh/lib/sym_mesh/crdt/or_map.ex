defmodule LemonMesh.Crdt.OrMap do
  @moduledoc false

  alias LemonMesh.Crdt.LwwRegister

  @enforce_keys [:entries]
  defstruct entries: %{}

  @type t :: %__MODULE__{
          entries: %{optional(String.t()) => LwwRegister.t(String.t())}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{entries: %{}}

  @spec new(map() | t() | nil) :: t()
  def new(%__MODULE__{} = map), do: map
  def new(nil), do: new()

  def new(map) when is_map(map) do
    entries =
      map
      |> Map.get(:entries, Map.get(map, "entries", map))
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), LwwRegister.new(value))
      end)

    %__MODULE__{entries: entries}
  end

  @spec set(t() | map() | nil, term(), term(), non_neg_integer(), String.t()) :: t()
  def set(or_map, key, value, timestamp, writer)
      when is_integer(timestamp) and timestamp >= 0 and is_binary(writer) do
    normalized = new(or_map)
    string_key = to_string(key)

    updated =
      normalized.entries
      |> Map.get(string_key, LwwRegister.new())
      |> LwwRegister.write(to_string(value), timestamp, writer)

    %{normalized | entries: Map.put(normalized.entries, string_key, updated)}
  end

  @spec get(t() | map() | nil, String.t()) :: String.t() | nil
  def get(or_map, key) when is_binary(key) do
    or_map
    |> new()
    |> Map.fetch!(:entries)
    |> Map.get(key)
    |> case do
      nil -> nil
      register -> LwwRegister.read(register)
    end
  end

  @spec len(t() | map() | nil) :: non_neg_integer()
  def len(or_map) do
    or_map
    |> new()
    |> Map.fetch!(:entries)
    |> map_size()
  end

  @spec empty?(t() | map() | nil) :: boolean()
  def empty?(or_map), do: len(or_map) == 0

  @spec merge(t() | map() | nil, t() | map() | nil) :: t()
  def merge(left, right) do
    left = new(left)
    right = new(right)

    merged =
      Map.merge(left.entries, right.entries, fn _key, left_register, right_register ->
        LwwRegister.merge(left_register, right_register)
      end)

    %__MODULE__{entries: merged}
  end

  @spec to_map(t() | map() | nil) :: map()
  def to_map(or_map) do
    or_map
    |> new()
    |> Map.fetch!(:entries)
    |> Enum.into(%{}, fn {key, register} -> {key, Map.from_struct(register)} end)
  end
end
