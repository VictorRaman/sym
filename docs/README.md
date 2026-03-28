# Lemon Documentation

This directory is the canonical documentation hub for maintainers. The root
[`README.md`](../README.md) is the operator entrypoint. The root
[`AGENTS.md`](../AGENTS.md) is the maintainer and AI-agent entrypoint. This
file routes deeper reading.

## Start Here

Read these first, in order:

| Doc | Why it matters |
| --- | --- |
| [platform_tiers.md](platform_tiers.md) | Canonical reduced-platform grading and profile membership |
| [architecture_boundaries.md](architecture_boundaries.md) | Canonical dependency policy and ownership boundaries |
| [config.md](config.md) | Runtime configuration contract |
| [quality_harness.md](quality_harness.md) | Quality checks, docs freshness rules, and cleanup |

These two files are the canonical generated tables and should be linked, not
reproduced elsewhere:

- [platform_tiers.md](platform_tiers.md)
- [architecture_boundaries.md](architecture_boundaries.md)

## Build & Operate

| Doc | Coverage |
| --- | --- |
| [config.md](config.md) | TOML sections, env overrides, secrets, runtime defaults |
| [quality_harness.md](quality_harness.md) | `mix lemon.quality`, cleanup, doc freshness, generated docs |
| [runtime-hot-reload.md](runtime-hot-reload.md) | Live code/config reload rules |
| [long-running-agent-harnesses.md](long-running-agent-harnesses.md) | Long-lived implementation and agent workflows |
| [testing/deterministic-test-patterns.md](testing/deterministic-test-patterns.md) | Deterministic Elixir test guidance |
| [testing/lemonade-stand-stress-test.md](testing/lemonade-stand-stress-test.md) | Stress harness notes |

## Architecture

| Doc | Coverage |
| --- | --- |
| [assistant_bootstrap_contract.md](assistant_bootstrap_contract.md) | Prompt/bootstrap assembly contract |
| [beam_agents.md](beam_agents.md) | BEAM agent-process model and supervision |
| [context.md](context.md) | Context shaping, compaction, token pressure |
| [mesh_runtime.md](mesh_runtime.md) | Historical durable-runtime design notes now absorbed into the kept apps |
| [model-selection-decoupling.md](model-selection-decoupling.md) | Model/provider/engine decoupling rationale |
| [telemetry.md](telemetry.md) | Telemetry events and observability |
| [diagrams/](diagrams/) | Excalidraw source plus exported SVG diagrams |

## Capabilities

| Doc | Coverage |
| --- | --- |
| [skills.md](skills.md) | Skill discovery, installation, lifecycle |
| [extensions.md](extensions.md) | Extension model and hook surfaces |
| [benchmarks.md](benchmarks.md) | Benchmark notes and baselines |
| [tools/web.md](tools/web.md) | Web search/fetch tooling |
| [tools/firecrawl.md](tools/firecrawl.md) | Firecrawl extractor notes |
| [tools/wasm.md](tools/wasm.md) | WASM tool runtime and behavior |
| [agent-loop/README.md](agent-loop/README.md) | Continuous improvement loop |

## Audience-Specific

These docs are intentionally off the main maintainer path.

| Doc | Audience |
| --- | --- |
| [audiences/for-dummies/README.md](audiences/for-dummies/README.md) | Plain-English system tour for non-Elixir readers |

## Plans & Archive

| Location | Purpose |
| --- | --- |
| [roadmap.md](roadmap.md) | Living roadmap and future work buckets |
| [plans/](plans/) | Active and reference implementation plans |
| [archive/reviews/](archive/reviews/) | Historical reviews and static analyses |
| [archive/worklog.md](archive/worklog.md) | Archived execution log material |

## App Guides

Per-app details live next to the app itself:

- `apps/*/README.md` for usage, dependencies, and test commands
- `apps/*/AGENTS.md` for maintainer workflow, local boundaries, and key files

Current kept apps:

- `apps/lemon_core/`
- `apps/ai/`
- `apps/coding_agent/`
- `apps/lemon_gateway/`
- `apps/lemon_control_plane/`

## Maintenance Rules

1. Every Markdown file under `docs/` must be listed in
   [`catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and
   `max_age_days`.
2. Run `mix lemon.quality` after doc moves, doc additions, or boundary changes.
3. Keep root `README.md` short and operator-focused.
4. Keep root `AGENTS.md` short and workflow-focused.
5. Put historical analysis in `docs/archive/`, not the repository root.

Last reviewed: 2026-03-26
