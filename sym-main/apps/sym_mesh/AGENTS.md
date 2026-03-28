# Lemon Mesh App Guide

`lemon_mesh` owns Lemon's single-node collaboration substrate.

## Purpose

- Durable mesh session manifests and blackboard state
- Durable peer mailbox envelopes with claim/lease/ack semantics
- Durable handoff bookkeeping for `mesh.agent.message`
- Background reconciliation for incomplete bookkeeping after router delivery succeeds

## Dependency Boundary

- Allowed umbrella deps: `lemon_core` only
- Do not add compile-time dependencies on `coding_agent`, `lemon_control_plane`, `lemon_router`, or `lemon_gateway`
- If another app needs mesh behavior, expose it through `LemonMesh.*` APIs instead of pulling foreign modules into this app

## Key Modules

| Module | Purpose |
|--------|---------|
| `LemonMesh` | Public API facade for sessions, blackboard, mailbox, and handoff state |
| `LemonMesh.Store` | Durable mesh session, blackboard, and peer mailbox storage |
| `LemonMesh.Session` | Live session GenServer; blackboard writes must remain durable-first |
| `LemonMesh.PeerEnvelope` | Typed mailbox envelope with lease and ack metadata |
| `LemonMesh.Op` | Internal append-only replication record for durable mesh state changes |
| `LemonMesh.OpLog` | Internal op-log store and causal clock allocator for future replication |
| `LemonMesh.CausalClock` | BEAM-native vector clock used for internal causal metadata |
| `LemonMesh.Crdt.*` | Internal CRDT primitives used for future replicated mesh state |
| `LemonMesh.Replication.Projector` | Internal projector that rebuilds compatibility read models from authoritative ops |
| `LemonMesh.Replication.Watermark` | Internal local watermark store for projected authoritative ops |
| `LemonMesh.Replication.Manager` | Dynamic trusted-peer membership manager driven by config reload |
| `LemonMesh.Replication.PeerWorker` | Pull-only replication worker for one trusted peer |
| `LemonMesh.Replication.Snapshot` | Snapshot builder/installer for compatibility tables |
| `LemonMesh.Replication.BeamRpc` | Pull-only BEAM RPC transport for snapshot and op backfill |
| `LemonMesh.HandoffStore` | Typed wrapper for durable handoff bookkeeping ops |
| `LemonMesh.HandoffDispatcher` | Orchestrates router delivery plus mailbox/blackboard bookkeeping |
| `LemonMesh.HandoffReconciler` | Retries incomplete bookkeeping legs without re-sending router delivery |

## Runtime Rules

- Peer mailbox is the durable delivery queue
- Blackboard is a collaboration ledger, not the prompt delivery queue
- `send_peer_message/2`, `claim_peer_messages/2`, and `ack_peer_message/3` should stay single-key atomic
- Envelope causal metadata (`origin_node_id`, `vector_clock`, `delivery_epoch`, `lease_epoch`) is durable-first; do not reintroduce ephemeral-only fields for delivery state
- Session metadata refresh after mailbox/blackboard mutations is best-effort and must not flip a successful primary mutation into an API error
- Running-session blackboard writes must still go through durable store-backed append; do not reintroduce in-memory-only success paths
- `handoff`, `peer_mailbox`, `blackboard`, and `manifest/session` are authoritative-op-first: append a durable `LemonMesh.Op`, project it into the compatibility read model, then advance local watermark state
- `peer_mailbox` authoritative ops are message-level deltas (`message_created`, `message_claimed`, `message_acked`), not whole-session mailbox snapshots; keep projector logic monotonic and message-scoped
- `blackboard` authoritative ops are append-only `entry_appended`; projector merge is by `entry_id` with stable ordering on `inserted_at_ms` / `entry_id`
- `manifest/session` authoritative ops are snapshot-style `manifest_upserted`; public read APIs still use the compatibility row, but runtime writes must not bypass the op-log
- `worktree_lease` is now an internal authoritative entity as well, but it is intentionally excluded from the current bootstrap snapshot contract
- Trusted peer membership is now reconciled dynamically from config reload events. v1 remains trusted-cluster and pull-only; do not add gossip, push replication, or federation paths here.
- Pull workers must fail closed when local authority state is already non-empty but no inbound watermark exists for that peer. Surface that as `needs_reseed`; do not silently fast-forward watermarks past missing history.
- Bootstrap is target-watermark based: snapshot install does not advance inbound watermark. A peer remains `bootstrapping` until inbound watermark covers `bootstrap_target_watermark`.
- `mesh.replication.status` now exposes `bootstrapTargetWatermark`, `backfillComplete`, and `backfillLag` as read-only observability fields.

## Handoff Rules

- `mesh.agent.message` is durable-first: create the authoritative handoff row, persist mailbox,
  persist blackboard, then attempt router fast-path delivery
- `deliveryAccepted=true` now means only that the optional router fast path accepted delivery
- Any successful `mesh.agent.message` response must already have durable mailbox and blackboard
  state in place
- Reconciliation may repair mailbox/blackboard bookkeeping from an existing handoff, but must never
  re-send router delivery
- Mailbox envelopes created from handoffs use `dedupe_key = handoff_id`
- `LemonMesh.HandoffStore.delivery_state` is an explicit lifecycle:
  `created -> delivery_accepted -> mailbox_persisted -> blackboard_persisted -> runtime_accepted -> runtime_applied -> completed`
- Runtime lifecycle timestamps are durable bookkeeping fields even though operator-facing APIs do not
  expose them yet; do not collapse the state machine back to coarse `accepted/failed` markers
- Successful handoff transitions must append and project a matching authoritative op (`created`, `delivery_accepted`, `mailbox_persisted`, etc.). Read-model rows are now rebuildable from the op-log; do not reintroduce write-first mirroring for handoffs.
- Ordinary read APIs must stay read-only. Do not reintroduce hidden `Projector.rebuild_entity/2`
  calls from `get_session`, `list_sessions`, `list_blackboard_entries`, or mailbox reads.

## Tests

- `mix test apps/lemon_mesh/test/lemon_mesh/blackboard_test.exs`
- `mix test apps/lemon_mesh/test/lemon_mesh/peer_mailbox_test.exs`
- Related control-plane coverage lives in `apps/lemon_control_plane/test/lemon_control_plane/mesh_agent_message_test.exs`
