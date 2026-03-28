defmodule LemonMesh.Crdt.LwwRegister do
  @moduledoc false

  @enforce_keys [:value, :timestamp, :writer]
  defstruct value: nil, timestamp: 0, writer: ""

  @type t(value_type) :: %__MODULE__{
          value: value_type | nil,
          timestamp: non_neg_integer(),
          writer: String.t()
        }

  @spec new() :: t(term())
  def new, do: %__MODULE__{value: nil, timestamp: 0, writer: ""}

  @spec new(map() | t(term()) | nil) :: t(term())
  def new(%__MODULE__{} = register), do: register
  def new(nil), do: new()

  def new(map) when is_map(map) do
    %__MODULE__{
      value: Map.get(map, :value, Map.get(map, "value")),
      timestamp: Map.get(map, :timestamp, Map.get(map, "timestamp", 0)),
      writer: to_string(Map.get(map, :writer, Map.get(map, "writer", "")))
    }
  end

  @spec write(t(term()) | map() | nil, term(), non_neg_integer(), String.t()) :: t(term())
  def write(register, value, timestamp, writer)
      when is_integer(timestamp) and timestamp >= 0 and is_binary(writer) do
    normalized = new(register)
    candidate = %__MODULE__{value: value, timestamp: timestamp, writer: writer}

    if dominates?(candidate, normalized) do
      candidate
    else
      normalized
    end
  end

  @spec read(t(term()) | map() | nil) :: term() | nil
  def read(register) do
    register
    |> new()
    |> Map.fetch!(:value)
  end

  @spec merge(t(term()) | map() | nil, t(term()) | map() | nil) :: t(term())
  def merge(left, right) do
    left = new(left)
    right = new(right)

    if dominates?(right, left), do: right, else: left
  end

  defp dominates?(left, right) do
    cond do
      left.timestamp > right.timestamp ->
        true

      left.timestamp < right.timestamp ->
        false

      left.writer > right.writer ->
        true

      left.writer < right.writer ->
        false

      true ->
        true
    end
  end
end
