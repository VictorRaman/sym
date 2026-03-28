# lemon

Lemon is a local-first AI assistant and coding-agent platform you run on your
own machine. It is organized as a deliberately reduced Elixir umbrella with one
canonical headless platform runtime.

The root README is intentionally short. It is the operator and quickstart
entrypoint, not the full architecture book.

## Start Here

- Want to run Lemon locally: use the quickstart below, then read
  [`docs/config.md`](docs/config.md).
- Want to understand platform layering: read
  [`docs/platform_tiers.md`](docs/platform_tiers.md) and
  [`docs/architecture_boundaries.md`](docs/architecture_boundaries.md).
- Want maintainer-facing navigation: start at [`AGENTS.md`](AGENTS.md) and
  [`docs/README.md`](docs/README.md).

## Quickstart

### Prerequisites

- Elixir 1.19+
- Erlang/OTP 27+
- One provider API key such as Anthropic or OpenAI
- No browser or UI runtime is required for the canonical platform

### Configure

Use [`examples/config.example.toml`](examples/config.example.toml) as the
starting point for `~/.lemon/config.toml`.

Common fields:

- `[defaults]` for default provider, model, and engine
- `[profiles.<id>]` for assistant profiles and tool policy
- `[gateway]` for Telegram, Discord, XMTP, SMS, and voice settings
- `[runtime]` for tools, compaction, CLI runners, and budget defaults

Full reference: [`docs/config.md`](docs/config.md)

### Run

```bash
# default platform profile
./bin/lemon

# core-only runtime
./bin/lemon --profile core
```

## Runtime Profiles

| Profile | Includes |
| --- | --- |
| `core` | `lemon_core`, `ai`, `coding_agent` |
| `platform` | `core` plus `lemon_gateway` and `lemon_control_plane` |

Canonical membership and keep rationale live in
[`docs/platform_tiers.md`](docs/platform_tiers.md).

## Repo Shape

| Area | Purpose |
| --- | --- |
| `apps/` | Elixir umbrella applications |
| `clients/` | TypeScript clients and browser tooling |
| `docs/` | Canonical maintainer documentation hub |
| `bin/` | Runtime launchers and helper scripts |
| `scripts/` | Utility scripts and isolated Mix wrapper |
| `examples/` | Sample config and extension stubs |

## Core Path

The normal runtime path is:

`lemon_control_plane -> lemon_gateway -> coding_agent -> ai`

Supporting concerns such as config, storage, bus, approvals, and absorbed
durable runtime state live in `lemon_core`.

## Common Commands

```bash
# install deps
mix deps.get

# compile
mix compile

# full test run
mix test

# quality gates
mix lemon.quality

# isolated targeted runs
scripts/mix_isolated.sh -- compile --warnings-as-errors
scripts/mix_isolated.sh -- lemon.quality
```

## Where To Read Next

### Operators

- [`docs/config.md`](docs/config.md)
- [`docs/quality_harness.md`](docs/quality_harness.md)
- [`docs/roadmap.md`](docs/roadmap.md)

### Maintainers

- [`AGENTS.md`](AGENTS.md)
- [`docs/README.md`](docs/README.md)
- [`docs/architecture_boundaries.md`](docs/architecture_boundaries.md)
- [`docs/platform_tiers.md`](docs/platform_tiers.md)

### Audience Guides

- [`docs/audiences/for-dummies/README.md`](docs/audiences/for-dummies/README.md)

## App Guides

Each app keeps its own `README.md` and `AGENTS.md` when it has meaningful local
context. Start from the root maintainer hub and then jump to the app guide you
need.

- [`apps/ai/README.md`](apps/ai/README.md)
- [`apps/coding_agent/README.md`](apps/coding_agent/README.md)
- [`apps/lemon_core/README.md`](apps/lemon_core/README.md)
- [`apps/lemon_gateway/README.md`](apps/lemon_gateway/README.md)
- [`apps/lemon_control_plane/README.md`](apps/lemon_control_plane/README.md)
