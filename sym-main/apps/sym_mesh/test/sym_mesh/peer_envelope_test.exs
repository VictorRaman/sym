defmodule LemonMesh.PeerEnvelopeTest do
  use ExUnit.Case, async: true

  alias LemonMesh.PeerEnvelope

  test "new assigns origin node metadata and default epochs" do
    envelope =
      PeerEnvelope.new(%{
        session_id: "mesh_1",
        to_agent: "reviewer",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this"},
        vector_clock: %{"node-a" => 2}
      })

    assert envelope.origin_node_id != nil
    assert envelope.vector_clock == %{"node-a" => 2}
    assert envelope.delivery_epoch == 0
    assert envelope.lease_epoch == 0
  end

  test "claim increments lease_epoch and sets lease metadata" do
    envelope =
      PeerEnvelope.new(%{
        session_id: "mesh_1",
        to_agent: "reviewer",
        payload_kind: "prompt",
        payload: %{"prompt" => "Review this"}
      })

    claimed =
      PeerEnvelope.claim(envelope, claimed_by: "session:abc", claimed_at_ms: 100, lease_ms: 50)

    assert claimed.claimed_by == "session:abc"
    assert claimed.claimed_at_ms == 100
    assert claimed.claim_expires_at_ms == 150
    assert claimed.lease_epoch == 1
  end
end
