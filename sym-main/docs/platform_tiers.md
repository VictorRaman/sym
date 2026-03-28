# Platform Tiers

Lemon is a multi-product platform, but not every umbrella app has the same
runtime criticality or product maturity. This document is the canonical
product-level grading for the umbrella.

Use this doc alongside:

- [`architecture_boundaries.md`](architecture_boundaries.md) for compile-time dependency policy
- [`quality_harness.md`](quality_harness.md) for CI and documentation gates
- root [`README.md`](../README.md) for operator-facing entrypoints
- root [`AGENTS.md`](../AGENTS.md) for engineering navigation

## Runtime Profiles

- `core`: runtime substrate only
- `platform`: core plus routing, delivery, and control-plane runtime
- `full`: current default full-bundle runtime surface

Incubator / sidecar apps are intentionally excluded from the `full` profile
unless they are promoted through an explicit platform decision.

## Generated Inventory

<!-- platform_manifest:start -->
| App | Tier | Status | Profiles | Owner | Keep Reason |
| --- | --- | --- | --- | --- | --- |

| `agent_core` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Shared BEAM agent loop and CLI-runner substrate. |
| `ai` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Unified provider runtime for every AI-backed execution path. |
| `coding_agent` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Primary coding runtime and tool-execution engine. |
| `coding_agent_ui` | `incubator` | `tooling_only` | *(none)* | @incubator | Thin RPC/UI abstraction kept for tooling compatibility, not platform runtime. |
| `lemon_automation` | `platform_runtime` | `stable` | `platform`, `full` | @platform-runtime | Scheduled submissions and heartbeats for long-running platform tasks. |
| `lemon_channels` | `platform_runtime` | `stable` | `platform`, `full` | @platform-runtime | Outbound presentation and channel adapters for real transports. |
| `lemon_control_plane` | `platform_runtime` | `stable` | `platform`, `full` | @platform-runtime | Primary RPC/WebSocket control surface for attached clients. |
| `lemon_core` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Shared config, store, pubsub, browser bridge, and quality harness. |
| `lemon_games` | `default_surface` | `stable` | `full` | @product-surface | Backs the public games platform exposed by lemon_web. |
| `lemon_gateway` | `platform_runtime` | `stable` | `platform`, `full` | @platform-runtime | Engine and transport execution runtime for platform entrypoints. |
| `lemon_mcp` | `incubator` | `incubating` | *(none)* | @incubator | MCP bridge remains exploratory and is not part of the default runtime. |
| `lemon_mesh` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Durable mailbox and handoff substrate used by coding runtime. |
| `lemon_router` | `platform_runtime` | `stable` | `platform`, `full` | @platform-runtime | Routing, run orchestration, conversation state, and queue semantics. |
| `lemon_services` | `incubator` | `sidecar` | *(none)* | @incubator | Standalone service manager kept as a sidecar capability outside default runtime. |
| `lemon_sim` | `default_surface` | `stable` | `full` | @product-surface | Simulation contracts consumed by the default sim UI. |
| `lemon_sim_ui` | `default_surface` | `stable` | `full` | @product-surface | Default-start sim surface for simulation harnesses. |
| `lemon_skills` | `runtime_core` | `stable` | `core`, `platform`, `full` | @platform-core | Skill registry is part of the core prompt/bootstrap contract. |
| `lemon_web` | `default_surface` | `stable` | `full` | @product-surface | Default LiveView dashboard and public games spectator surface. |
| `market_intel` | `incubator` | `incubating` | *(none)* | @incubator | Experimental market-data/commentary product line kept outside default runtime. |
<!-- platform_manifest:end -->
