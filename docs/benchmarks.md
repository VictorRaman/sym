# Performance Benchmarks

This repository no longer ships a committed `bench/` tree. The reduced Lemon
platform keeps performance verification lightweight and reproducible:

- use `mix lemon.eval` for deterministic/stability workflow checks
- use targeted `mix test` runs around hot paths before and after changes
- add ad-hoc Benchee scripts locally when a specific performance question
  justifies them, but do not assume a permanent benchmark suite exists

## Current Baseline

The active performance-sensitive areas live under:

| Area | Current path |
| --- | --- |
| agent runtime primitives | `apps/coding_agent/lib/agent_core/` |
| coding runtime/session orchestration | `apps/coding_agent/lib/coding_agent/` |
| gateway execution lifecycle | `apps/lemon_gateway/lib/lemon_gateway/` |

## Recommended Verification

Use the quality/eval harness first:

```bash
mix lemon.eval
scripts/mix_isolated.sh -- compile --warnings-as-errors
scripts/mix_isolated.sh -- lemon.quality
```

For targeted regressions, run the narrowest test or script that exercises the
hot path you changed:

```bash
scripts/mix_isolated.sh --cwd apps/coding_agent -- test test/coding_agent/session_test.exs
scripts/mix_isolated.sh --cwd apps/lemon_gateway -- test test/engines/codex_engine_test.exs
```

## Ad-Hoc Benchmarking

If you need a one-off benchmark:

1. Create a local `.exs` script outside the tracked mainline or under a clearly
   temporary scratch path.
2. Benchmark only the question at hand.
3. Record the result in the relevant plan/review doc if it materially changes a
   design decision.
4. Delete the script when it stops carrying its weight.

That keeps the mainline aligned with the current Linux-style constraint: fewer
artifacts, fewer stale paths, and only the verification surfaces that still
earn their keep.
