# Lemon Mesh Runtime

> Durable collaboration state and BEAM-local mailbox delivery for Lemon Mesh.

## What Exists Today

Lemon Mesh currently has three concrete layers:

1. Durable mesh sessions plus blackboard state in `lemon_mesh`
2. Durable peer mailbox envelopes plus control-plane APIs
3. Session-side runtime pull for `coding_agent`

This started as single-node and BEAM-local. It now has a minimal trusted-peer, pull-only replication
layer, but it is not yet a full cross-node authoritative mesh for every entity.

## Responsibility Split

- `blackboard`
  - Shared collaboration ledger for facts, decisions, handoffs, and task lifecycle events
  - Write-through durable state for active and persisted mesh sessions
  - Not used as the delivery queue for agent prompts

- `peer mailbox`
  - Directed message envelopes addressed to a target agent inside a mesh session
  - Durable store-backed queue independent of the live mesh session process
  - Backing store for `mesh.agent.message`, `mesh.agent.mailbox.list`, and runtime pull

- router / control plane
  - `mesh.agent.message` still uses the existing router send path for actual agent delivery
  - It records a durable handoff op, persists a mailbox envelope, and appends a blackboard handoff entry
  - Delivery and bookkeeping are coordinated, but still not atomically committed

## Mailbox Envelope Contract

Each peer mailbox envelope carries:

- addressing: `session_id`, `from_agent`, `to_agent`, `channel`
- causal metadata: `origin_node_id`, `vector_clock`, `delivery_epoch`
- payload: `payload_kind`, `payload`, `payload_ref`
- bookkeeping: `message_id`, `dedupe_key`, `inserted_at_ms`
- lease state: `claimed_at_ms`, `claim_expires_at_ms`, `claimed_by`, `lease_epoch`
- ack state: `acknowledged_at_ms`, `acknowledged_by`
- metadata: free-form map, including normalized `queue_mode` for control-plane prompts

Claim metadata is preserved after ack so operators can still see who consumed a message.
Runtime consumers use session-scoped claimants in the form `session:<session_id>`, not bare `agent_id`.

## Runtime Pull Semantics

`coding_agent` sessions can opt into runtime pull when they are started with both:

- `agent_id`
- `mesh_session_id`

When enabled, the session periodically polls Lemon Mesh and:

1. claims one pending `payload_kind == "prompt"` envelope for its `agent_id`
2. records a durable runtime acceptance journal entry
3. acks the mailbox envelope
4. starts one deferred runtime prompt when the session is idle, or queues the injection when the
   session is already streaming

Mailbox ack now means the session durably accepted the envelope into its runtime mailbox journal.
It does not mean the prompt is already durable conversation history. Runtime pull therefore still
remains at-least-once rather than exactly-once.

The acceptance journal is keyed by session-local `envelope_id` and is replayed on session startup
before the next mailbox poll. Replay is strictly one pending entry at a time. Journal entries are
only marked applied after the corresponding runtime user message is persisted and saved.
Internally each entry now also carries an `op_id` plus `accepted_clock` / `applied_clock` metadata
so future replicated apply ledgers can attach to durable runtime state without changing the current
operator-facing contract.
Runtime-injected user messages persist matching metadata as well. Apply finalization now prefers
`op_id` / `envelope_id` from `Ai.Types.UserMessage.metadata` and only falls back to legacy
`text + timestamp` matching for older session files and older in-memory journal refs.

`lemon_mesh` now also maintains an internal append-only op-log foundation for durable mesh state
changes. For `handoff`, `peer_mailbox`, `blackboard`, and `manifest/session`, that log is now the
authoritative write path: each transition appends a durable op, projects it into the current
compatibility read model, and advances a local watermark so those tables can be rebuilt from ops
alone.

`peer_mailbox` has now moved to message-level delta ops:

- `message_created`
- `message_claimed`
- `message_acked`

Those ops target one mailbox message at a time and are projected back into the existing
session-scoped compatibility table. The projector still accepts older session-snapshot mailbox ops
for replay compatibility, but new writes should stay message-scoped.

Trusted peers are now configured under `[mesh]` and reconciled dynamically on config reload.
Each trusted peer gets one pull-only replication worker that:

1. fetches a `mesh_state` snapshot
2. installs it only when the local authority state is empty
3. records the snapshot watermark as `bootstrapTargetWatermark`
4. tracks per-peer inbound/outbound watermarks
5. periodically pulls new ops over BEAM RPC

If local authority state is already present but the peer has no inbound watermark yet, the worker
does not fast-forward. It enters a `needs_reseed` state instead so operators can re-bootstrap
explicitly rather than silently skipping missing history.

Bootstrap completion is now target-watermark based:

- `bootstrapping` means the snapshot target watermark has not been covered by inbound watermark yet
- `bootstrapped` means inbound watermark now covers `bootstrapTargetWatermark`
- `needs_reseed` means local authority state exists but the peer has no inbound watermark

`mesh.replication.status` now exposes:

- `bootstrapTargetWatermark`
- `backfillComplete`
- `backfillLag`

Queue-mode mapping is intentionally narrow:

- `followup` and `collect` become runtime prompts
- `steer`, `steer_backlog`, and `interrupt` become steering-style runtime prompts while idle, and
  queue-backed steering injections while a run is already active

`interrupt` is currently a mailbox-level steering hint, not a hard in-stream interrupt. If the
session is already streaming, mailbox pull waits until the session becomes idle again.

The consumer is at-least-once:

- claim uses a lease
- failed journal writes do not ack the message
- failed post-ack injection stays recoverable via journal replay
- failed post-ack save leaves the journal entry pending until a later replay after restart
- the envelope becomes visible again after lease expiry

## Claim / Lease Rules

- default mailbox list queries only return envelopes that are:
  - not acknowledged
  - not currently protected by an active lease
- `claim_peer_messages/2` is the core atomic step used by runtime pull
- `ack_peer_message/3` can enforce:
  - `expected_to_agent`
  - `expected_claimed_by`

The claimant guard is used by runtime pull to avoid acknowledging another consumer's lease.

## Control-Plane Visibility

- `mesh.agent.mailbox.list` defaults to pending, unclaimed messages only
- `includeClaimed=true` exposes unacknowledged envelopes for that agent, including messages that
  currently have an active lease
- claimed envelopes include `claimedAtMs`, `claimExpiresAtMs`, and `claimedBy`

## Handoff Workflow

`mesh.agent.message` is now durable-first:

- `mailboxPersisted=true` means the durable peer mailbox envelope exists
- `blackboardPersisted=true` means the handoff ledger entry exists
- `deliveryAccepted=true` means the optional router fast path accepted the agent delivery request
- `handoffId` is the durable bookkeeping key used for reconciliation

Internally the durable handoff lifecycle is now explicit rather than a single accepted bit:

- `created`
- `delivery_accepted`
- `mailbox_persisted`
- `blackboard_persisted`
- `runtime_accepted`
- `runtime_applied`
- `completed`
- `failed`

The ordering is now:

1. durable handoff row
2. durable mailbox envelope
3. durable blackboard handoff entry
4. optional router fast-path delivery

Ordinary read APIs no longer rebuild compatibility tables on demand. Projection rebuild is an
explicit maintenance/bootstrap action, not a hidden side effect of reads.

If mailbox or blackboard persistence fails, the method returns an error and does not attempt live
router delivery. Reconciliation may repair those durable bookkeeping legs later because the
authoritative handoff row already exists. If router delivery fails after durability is already in
place, the method still returns success with `deliveryAccepted=false`; the durable mailbox remains
the source of truth for eventual runtime delivery.

Current runtime wiring updates the internal handoff store with `runtime_accepted` /
`runtime_applied` timestamps when the mailbox message carries a `handoff_id`, but operator-facing
method responses remain unchanged. Background reconciliation is now explicitly limited to mailbox
and blackboard bookkeeping; it does not re-send router delivery and it does not mark the handoff
`completed`. Internal completion is only recorded once the runtime path marks the handoff
`runtime_applied`.

## Known Limits

- `worktree_lease` is now internally authoritative, but it is not part of the current bootstrap snapshot contract
- trusted-peer replication is pull-only and operator-controlled via config reload
- no CRDT/shared-file collaboration yet
- no replay cursor, dead-letter queue, or explicit release API yet
- causal metadata and local watermarks are now durable for authoritative entities, but still BEAM-local only; they are not yet replicated
- compatibility read models no longer self-heal on reads; when a projection is missing, recovery
  must happen through explicit projector rebuild or snapshot/reseed flows
