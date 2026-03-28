# Lemon Agent Guide

This file is the maintainer and AI-agent entrypoint for the Lemon repository.
It stays operational on purpose. Durable architecture detail belongs in
[`docs/`](docs/README.md), not here.

## Read Order

1. [`docs/platform_tiers.md`](/mnt/e/lemon-main/docs/platform_tiers.md)
2. [`docs/architecture_boundaries.md`](/mnt/e/lemon-main/docs/architecture_boundaries.md)
3. [`docs/README.md`](/mnt/e/lemon-main/docs/README.md)
4. The relevant app-level guide under `apps/*/AGENTS.md`

## Quick Navigation

| If you want to... | Start in... |
| --- | --- |
| Work on provider support | `apps/ai/` |
| Modify the coding runtime or tools | `apps/coding_agent/` |
| Change engine lifecycle, routing, or gateway transports | `apps/lemon_gateway/` |
| Change config, store, approvals, or absorbed durable state | `apps/lemon_core/` |
| Change control-plane RPC / WebSocket APIs | `apps/lemon_control_plane/` |
| Work on TypeScript clients or browser node | `clients/` |

## Platform Tiers

Lemon is not a single app. Treat app importance and runtime membership according
to [`docs/platform_tiers.md`](/mnt/e/lemon-main/docs/platform_tiers.md). Treat
dependency legality according to
[`docs/architecture_boundaries.md`](/mnt/e/lemon-main/docs/architecture_boundaries.md).

High-level groups:

- `runtime_core`: `lemon_core`, `ai`, `coding_agent`
- `platform_runtime`: `lemon_gateway`, `lemon_control_plane`

## Parallel Work

When multiple agents or parallel tasks are involved, use git worktrees under
`.worktrees/` at the repository root.

Golden rule:

> Never have multiple agents editing the same working directory simultaneously.

Suggested flow:

```bash
mkdir -p .worktrees
git worktree add .worktrees/<task-name> -b <task-name>
cd .worktrees/<task-name>
```

## Documentation Contract

Work is not complete until the documentation that describes the changed behavior
is also updated.

When you change code, update the relevant:

- `AGENTS.md`
- `README.md`
- `docs/*.md`
- inline comments for non-obvious logic
- config examples and related config docs

If you changed how something works, update the document people will read to
understand that thing.

## Common Commands

```bash
mix deps.get
mix compile
mix test
mix format
mix lemon.quality
```

Prefer isolated runs when parallel Mix commands may exist:

```bash
scripts/mix_isolated.sh -- compile --warnings-as-errors
scripts/mix_isolated.sh -- lemon.quality
scripts/mix_isolated.sh --cwd apps/lemon_gateway -- test
```

Client work:

```bash
cd clients/lemon-tui && npm run build && npm run test:coverage
cd clients/lemon-web && npm run build && npm run test:coverage
cd clients/lemon-browser-node && npm run build && npm run test:coverage
```

## Architecture Snapshot

Primary runtime path:

`lemon_control_plane -> lemon_gateway -> coding_agent -> ai`

Ownership shorthand:

- `lemon_gateway` owns execution lifecycle plus absorbed routing, delivery, and automation concerns
- `lemon_control_plane` owns RPC / WebSocket APIs
- `coding_agent` owns the coding runtime plus absorbed agent-loop and skills behavior
- `lemon_core` owns shared primitives, storage, config, bus, and absorbed durable runtime state

If you need the full dependency table or architecture narrative, go to
[`docs/README.md`](/mnt/e/lemon-main/docs/README.md).

## Documentation Hub

The canonical maintainer hub is [`docs/README.md`](/mnt/e/lemon-main/docs/README.md).

Start there for:

- architecture docs
- build and operate guides
- capability docs
- audience-specific material
- plans and archive material

## App-Specific Guides

Each app below has maintainer-facing local context:

| App | Guide |
| --- | --- |
| `ai` | `apps/ai/AGENTS.md` |
| `coding_agent` | `apps/coding_agent/AGENTS.md` |
| `lemon_control_plane` | `apps/lemon_control_plane/AGENTS.md` |
| `lemon_core` | `apps/lemon_core/AGENTS.md` |
| `lemon_gateway` | `apps/lemon_gateway/AGENTS.md` |

## Conventions

- Elixir: snake_case files, CamelCase modules
- TypeScript: follow workspace ESLint config
- Tests: `*_test.exs` or `*.test.ts`
- Commits: short imperative style

Last updated: 2026-03-26
