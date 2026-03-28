defmodule LemonMesh.Op do
  @moduledoc false

  alias LemonCore.Id
  alias LemonMesh.{CausalClock, NodeIdentity}

  @enforce_keys [
    :op_id,
    :origin_node_id,
    :entity_type,
    :entity_id,
    :op_type,
    :causal_clock,
    :lease_epoch,
    :payload,
    :recorded_at_ms
  ]
  defstruct [
    :op_id,
    :origin_node_id,
    :entity_type,
    :entity_id,
    :op_type,
    :causal_clock,
    :lease_epoch,
    :payload,
    :recorded_at_ms
  ]

  @type t :: %__MODULE__{
          op_id: String.t(),
          origin_node_id: String.t(),
          entity_type: String.t(),
          entity_id: String.t(),
          op_type: String.t(),
          causal_clock: map(),
          lease_epoch: non_neg_integer(),
          payload: map(),
          recorded_at_ms: non_neg_integer()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = normalize_map(attrs)

    %__MODULE__{
      op_id: fetch(attrs, :op_id, "op_#{Id.uuid()}"),
      origin_node_id: fetch(attrs, :origin_node_id, NodeIdentity.current_node_id()),
      entity_type: fetch_required_string!(attrs, :entity_type),
      entity_id: fetch_required_string!(attrs, :entity_id),
      op_type: fetch_required_string!(attrs, :op_type),
      causal_clock:
        attrs |> fetch(:causal_clock, %{}) |> CausalClock.new() |> CausalClock.to_map(),
      lease_epoch: normalize_epoch(fetch(attrs, :lease_epoch, 0)),
      payload: normalize_payload(fetch(attrs, :payload, %{})),
      recorded_at_ms: fetch(attrs, :recorded_at_ms, System.system_time(:millisecond))
    }
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = op) do
    %{
      op_id: op.op_id,
      origin_node_id: op.origin_node_id,
      entity_type: op.entity_type,
      entity_id: op.entity_id,
      op_type: op.op_type,
      causal_clock: op.causal_clock,
      lease_epoch: op.lease_epoch,
      payload: op.payload,
      recorded_at_ms: op.recorded_at_ms
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
      value -> raise ArgumentError, "missing op field #{inspect(key)}: #{inspect(value)}"
    end
  end

  defp normalize_epoch(value) when is_integer(value) and value >= 0, do: value
  defp normalize_epoch(_value), do: 0

  defp normalize_payload(value) when is_map(value), do: value
  defp normalize_payload(_value), do: %{}
end
