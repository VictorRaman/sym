# Platform Tiers

Lemon is a reduced headless platform. This document is the canonical runtime
grading for the kept umbrella apps.

Use this doc alongside:

- [`architecture_boundaries.md`](architecture_boundaries.md) for compile-time dependency policy
- [`quality_harness.md`](quality_harness.md) for CI and documentation gates
- root [`README.md`](../README.md) for operator-facing entrypoints
- root [`AGENTS.md`](../AGENTS.md) for engineering navigation

## Runtime Profiles

- `core`: local coding substrate only
- `platform`: core plus gateway and control-plane runtime

## Generated Inventory

<!-- platform_manifest:start -->
| App | Tier | Status | Profiles | Owner | Keep Reason |
| --- | --- | --- | --- | --- | --- |

| `ai` | `runtime_core` | `stable` | `core`, `platform` | @platform-core | Unified provider runtime for every AI-backed execution path. |
| `coding_agent` | `runtime_core` | `stable` | `core`, `platform` | @platform-core | Primary coding runtime with absorbed agent loop, skills, and session tooling. |
| `lemon_control_plane` | `platform_runtime` | `stable` | `platform` | @platform-runtime | Canonical RPC and WebSocket control surface for the headless platform. |
| `lemon_core` | `runtime_core` | `stable` | `core`, `platform` | @platform-core | Shared config, store, secrets, persistence, and quality harness. |
| `lemon_gateway` | `platform_runtime` | `stable` | `platform` | @platform-runtime | Unified platform runtime with absorbed routing, channel delivery, and automation. |
<!-- platform_manifest:end -->
