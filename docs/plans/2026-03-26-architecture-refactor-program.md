# Architecture Refactor Program

> Reference program extracted from the archived static review in
> [`../archive/reviews/2026-03-26-static-architecture-review.md`](../archive/reviews/2026-03-26-static-architecture-review.md).

## Summary

This plan captures the architecture improvements recommended by the static
review without leaving the repository root cluttered with ad hoc planning
documents.

The overall direction remains:

- keep the current umbrella split
- do not collapse runtime apps
- reduce hotspot module size
- strengthen source-of-truth policy and lifecycle vocabulary

## Ordered Workstreams

### 1. Architecture policy source of truth

- Keep `docs/architecture_boundaries.md` generated from one canonical policy
  module.
- Prevent drift between code-enforced dependency policy and maintainer docs.
- Validate with architecture docs generation plus `mix lemon.quality`.

### 2. Canonical run phase model

- Keep one shared run-phase vocabulary across router and gateway handoff points.
- Use that vocabulary for observability and progress reporting instead of
  subsystem-local lifecycle names.
- Validate with focused router/gateway tests.

### 3. SessionCoordinator state extraction

- Continue shrinking `SessionCoordinator` into explicit state and transition
  modules.
- Preserve router-owned queue semantics while making transitions easier to test.
- Validate with focused router tests plus quality gates.

## Constraints

- `lemon_router` keeps conversation and queue semantics.
- `lemon_gateway` keeps execution lifecycle and slot scheduling.
- `lemon_channels` keeps rendering and transport presentation state.
- `lemon_control_plane` keeps RPC/API ownership.
- `lemon_core` remains the shared primitives layer, even if internal
  subdomains continue to sharpen.

## Validation Baseline

```bash
mix test apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs
mix test apps/lemon_core/test/lemon_core/quality/architecture_rules_check_test.exs
mix test apps/lemon_core/test/mix/tasks/lemon.quality_test.exs
mix lemon.quality
```

Additional targeted validation for later workstreams:

```bash
mix test apps/lemon_router
mix test apps/lemon_gateway
```
