defmodule LemonMesh.PeerEnvelope do
  @moduledoc """
  Typed envelope for BEAM-local peer mailbox messages.

  This slice persists directed mesh messages so they can be listed and
  acknowledged independently of the live session process.
  """

  alias LemonCore.Id
  alias LemonMesh.{CausalClock, NodeIdentity}

  @type t :: %__MODULE__{
          message_id: String.t(),
          session_id: String.t() | nil,
          from_agent: String.t() | nil,
          to_agent: String.t() | nil,
          channel: String.t() | nil,
          vector_clock: map(),
          origin_node_id: String.t() | nil,
          delivery_epoch: non_neg_integer(),
          payload_kind: String.t() | nil,
          payload_ref: term(),
          payload: term(),
          dedupe_key: String.t(),
          inserted_at_ms: non_neg_integer(),
          claimed_at_ms: non_neg_integer() | nil,
          claim_expires_at_ms: non_neg_integer() | nil,
          claimed_by: String.t() | nil,
          lease_epoch: non_neg_integer(),
          acknowledged_at_ms: non_neg_integer() | nil,
          acknowledged_by: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :message_id,
    :session_id,
    :from_agent,
    :to_agent,
    :channel,
    :origin_node_id,
    :payload_kind,
    :payload_ref,
    :payload,
    vector_clock: %{},
    delivery_epoch: 0,
    dedupe_key: nil,
    inserted_at_ms: 0,
    claimed_at_ms: nil,
    claim_expires_at_ms: nil,
    claimed_by: nil,
    lease_epoch: 0,
    acknowledged_at_ms: nil,
    acknowledged_by: nil,
    metadata: %{}
  ]

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize(attrs)
    message_id = fetch(attrs, :message_id, "msg_#{Id.uuid()}")

    %__MODULE__{
      message_id: message_id,
      session_id: fetch(attrs, :session_id),
      from_agent: fetch(attrs, :from_agent),
      to_agent: fetch(attrs, :to_agent),
      channel: fetch(attrs, :channel),
      origin_node_id: fetch(attrs, :origin_node_id, NodeIdentity.current_node_id()),
      vector_clock: CausalClock.to_map(fetch(attrs, :vector_clock, %{}) || %{}),
      delivery_epoch: normalize_epoch(fetch(attrs, :delivery_epoch, 0)),
      payload_kind: fetch(attrs, :payload_kind),
      payload_ref: fetch(attrs, :payload_ref),
      payload: fetch(attrs, :payload, %{}),
      dedupe_key: fetch(attrs, :dedupe_key, message_id),
      inserted_at_ms: fetch(attrs, :inserted_at_ms, System.system_time(:millisecond)),
      claimed_at_ms: fetch(attrs, :claimed_at_ms),
      claim_expires_at_ms: fetch(attrs, :claim_expires_at_ms),
      claimed_by: fetch(attrs, :claimed_by),
      lease_epoch: normalize_epoch(fetch(attrs, :lease_epoch, 0)),
      acknowledged_at_ms: fetch(attrs, :acknowledged_at_ms),
      acknowledged_by: fetch(attrs, :acknowledged_by),
      metadata: fetch(attrs, :metadata, %{}) || %{}
    }
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map), do: new(map)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      message_id: envelope.message_id,
      session_id: envelope.session_id,
      from_agent: envelope.from_agent,
      to_agent: envelope.to_agent,
      channel: envelope.channel,
      origin_node_id: envelope.origin_node_id,
      vector_clock: envelope.vector_clock,
      delivery_epoch: envelope.delivery_epoch,
      payload_kind: envelope.payload_kind,
      payload_ref: envelope.payload_ref,
      payload: envelope.payload,
      dedupe_key: envelope.dedupe_key,
      inserted_at_ms: envelope.inserted_at_ms,
      claimed_at_ms: envelope.claimed_at_ms,
      claim_expires_at_ms: envelope.claim_expires_at_ms,
      claimed_by: envelope.claimed_by,
      lease_epoch: envelope.lease_epoch,
      acknowledged_at_ms: envelope.acknowledged_at_ms,
      acknowledged_by: envelope.acknowledged_by,
      metadata: envelope.metadata
    }
  end

  @spec claim(t(), keyword() | map()) :: t()
  def claim(%__MODULE__{} = envelope, attrs \\ %{}) do
    attrs = normalize(attrs)
    claimed_at_ms = fetch(attrs, :claimed_at_ms, System.system_time(:millisecond))
    lease_ms = fetch(attrs, :lease_ms, 60_000)

    %{
      envelope
      | claimed_at_ms: claimed_at_ms,
        claim_expires_at_ms: claimed_at_ms + normalize_lease_ms(lease_ms),
        claimed_by: fetch(attrs, :claimed_by),
        lease_epoch: normalize_epoch(fetch(attrs, :lease_epoch, envelope.lease_epoch + 1))
    }
  end

  @spec acknowledge(t(), keyword() | map()) :: t()
  def acknowledge(%__MODULE__{} = envelope, attrs \\ %{}) do
    attrs = normalize(attrs)

    %{
      envelope
      | acknowledged_at_ms: fetch(attrs, :acknowledged_at_ms, System.system_time(:millisecond)),
        acknowledged_by: fetch(attrs, :acknowledged_by)
    }
  end

  @spec claim_active?(t(), non_neg_integer()) :: boolean()
  def claim_active?(%__MODULE__{} = envelope, now_ms \\ System.system_time(:millisecond)) do
    is_nil(envelope.acknowledged_at_ms) and
      is_integer(envelope.claim_expires_at_ms) and
      envelope.claim_expires_at_ms > now_ms
  end

  defp normalize(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp normalize_lease_ms(lease_ms) when is_integer(lease_ms) and lease_ms >= 0, do: lease_ms
  defp normalize_lease_ms(_lease_ms), do: 60_000

  defp normalize_epoch(value) when is_integer(value) and value >= 0, do: value
  defp normalize_epoch(_value), do: 0

  defp fetch(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
