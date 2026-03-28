# Mesh Durable-First and CodingAgent Stabilization

## Summary

This implementation pass closed the main structural gap in Lemon Mesh handoff delivery and reduced the remaining `coding_agent` full-suite instability to test-boundary fixes.

The key decisions were:

- `mesh.agent.message` is durable-first.
- ordinary `lemon_mesh` read APIs no longer perform hidden projector rebuilds.
- `coding_agent` coordinator and lane-queue tests must assert the real cleanup contract rather than brittle scheduler windows.

## Mesh Changes

- Handoff dispatch now persists the authoritative handoff row, mailbox envelope, and blackboard entry before optional router fast-path delivery.
- Router failure is no longer treated as a durability failure.
- Reconciliation repairs durable mailbox/blackboard bookkeeping only; it does not re-send router delivery.
- Hidden read-side rebuilds were removed from ordinary session/blackboard/mailbox reads.
- Missing mailbox projection during reconcile is repaired explicitly through projector rebuild instead of ordinary read-side self-healing.

## CodingAgent Stabilization

- `LaneQueue` no longer logs duplicate completion warnings for successful jobs.
- Coordinator cleanup tests were aligned to eventual-empty semantics under full-suite load.
- Bash cancellation partial-output tests were widened to tolerate realistic buffering latency.
- Process store server tests now clear the shared ETS table up front to avoid cross-test contamination.
- `LemonSubagent` API export checks now force module loading before export assertions.
- Multi-subscriber session event tests now use wider, full-suite-safe receive windows.

## Verification

Fresh verification obtained during this pass:

- `./scripts/mix_isolated.sh --cwd apps/lemon_mesh -- test`
- `./scripts/mix_isolated.sh --cwd apps/lemon_control_plane -- test`
- filtered full `./scripts/mix_isolated.sh --cwd apps/coding_agent -- test`

Observed results at the end of the pass:

- `apps/lemon_mesh`: `6 properties, 65 tests, 0 failures`
- `apps/lemon_control_plane`: `623 tests, 0 failures`
- `apps/coding_agent`: filtered full-suite reached `3709 tests, 0 failures (82 excluded)`

## Remaining Hygiene

- `docs/plans/` now exists as the process record for this work.
- Root-level reference artifacts outside `lemon-main` remain present:
  - `llm-sync-main`
  - `lemon-main.tar`
  - `lemon-main1.zip`

They are not referenced by `lemon-main` runtime code and should be treated as non-runtime workspace artifacts unless future import/use proves otherwise.
