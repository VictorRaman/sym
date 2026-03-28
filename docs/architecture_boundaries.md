# Architecture Boundaries

Lemon enforces direct umbrella dependencies by app. This keeps the reduced
platform modular and prevents layer drift.

Dependency legality is not the same as product criticality. For runtime/profile
grading and incubator status, see [`platform_tiers.md`](platform_tiers.md).

## Direct Dependency Policy

<!-- architecture_policy:start -->
| App | Allowed direct umbrella deps |
| --- | --- |

| `ai` | `lemon_core` |
| `coding_agent` | `ai`, `lemon_core` |
| `lemon_control_plane` | `ai`, `coding_agent`, `lemon_core`, `lemon_gateway` |
| `lemon_core` | *(none)* |
| `lemon_gateway` | `ai`, `coding_agent`, `lemon_core` |
<!-- architecture_policy:end -->

## Enforcement

Run:

```bash
mix lemon.quality
```

The architecture checker enforces both:
- direct umbrella dependencies from `apps/*/mix.exs`
- namespace references in `apps/*/lib/**/*.ex` (forbidden cross-app module usage)

It fails if any app introduces either an out-of-policy direct dependency or an out-of-policy cross-app namespace reference.

## Runtime Ownership Rules

The refactor quality rules also enforce a few concrete ownership boundaries:

- `lemon_gateway` owns execution lifecycle plus absorbed router, channel, and automation behavior.
- `lemon_control_plane` is the only canonical external API surface.
- `coding_agent` owns the coding runtime plus absorbed agent-loop, UI, and skills behavior.
- `lemon_core` owns shared persistence, config, approvals, and absorbed durable runtime state.
- Shared domains in `lemon_core` / `lemon_control_plane` must use typed wrappers such as `RunStore`, `ChatStateStore`, `PolicyStore`, and `ProjectBindingStore` instead of bypassing them with raw store helpers.

Run `mix lemon.quality` after boundary changes. It now checks both dependency policy and these architecture guardrails.
