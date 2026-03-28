# Quality Harness

Lemon now uses a multi-layer quality harness:

1. Docs quality checks (ownership, freshness, broken local links)
2. Architecture boundary checks (direct umbrella dependency policy)
3. Coverage and compile gates (`mix test --cover`, Vitest coverage, warnings-as-errors)
4. Production dependency audits for shipped Node clients (`npm audit --omit=dev --audit-level=high`)
5. Coding eval harness (deterministic, statistical, and workflow checks)
6. Entropy cleanup scan/prune for `docs/agent-loop/runs`, repo-local tmp/log residue, Lemon-owned `/tmp`
   artifacts, and reportable local build artifacts such as `_build`, `_codex_build`, `deps`,
   `native/*/target`, `clients/**/dist`, and `node_modules`

## Commands

```bash
# Docs + architecture checks
mix lemon.quality
mix lemon.architecture.docs --check
mix lemon.platform.docs --check

# Umbrella test coverage
mix test --cover --exclude integration

# Coding eval harness
mix lemon.eval
mix lemon.eval --iterations 50

# Cleanup scan (dry-run)
mix lemon.cleanup

# Cleanup with deletion for run/tmp residue
mix lemon.cleanup --apply --retention-days 21

# Cleanup with deletion including local build artifacts
mix lemon.cleanup --apply --build-artifacts --retention-days 21

# Override tmp scan root when needed
mix lemon.cleanup --tmp-root /tmp

# Codex smoke preflight (checks local config + codex CLI only)
./scripts/control_plane_codex_smoke.mjs --check-only

# Real control-plane Codex smoke
./scripts/control_plane_codex_smoke.mjs --url ws://127.0.0.1:4040/ws
```

For targeted regressions or any environment where multiple `mix` processes may run in parallel,
prefer the isolated wrapper so each verification run gets its own build/cache roots and a toolchain
preflight:

```bash
# Targeted per-app checks
scripts/mix_isolated.sh --cwd apps/coding_agent -- test test/coding_agent/tools/mesh_mailbox_test.exs
scripts/mix_isolated.sh --cwd apps/lemon_control_plane -- test test/lemon_control_plane/methods/agent_chat_methods_test.exs

# Umbrella quality/compile gates
scripts/mix_isolated.sh -- compile --warnings-as-errors
scripts/mix_isolated.sh -- lemon.quality

# Pin a specific local toolchain when your shell still points at an older Elixir
scripts/mix_isolated.sh --toolchain-bin "$HOME/.elixir-install/installs/elixir/1.19.5-otp-27/bin" -- lemon.quality
```

The wrapper checks for Elixir `1.19+` before invoking `mix`, exports isolated `MIX_BUILD_ROOT`,
`REBAR_BASE_DIR`, and `XDG_CACHE_HOME` paths, preserves failed build roots for inspection, and
auto-selects a newer local `~/.elixir-install` toolchain when PATH is still pinned to an older
Elixir.

The Codex smoke script now fails fast on local prerequisites before it touches the control plane.
Its preflight expects:

- `~/.lemon/config.toml` or `--config-path <path>`
- `[runtime.cli.codex]`
- `[gateway]`
- a working `codex` binary or `--codex-bin <path>`

Use `--check-only` when you want to validate those prerequisites without starting a run.

## Eval Classes

`mix lemon.eval` runs:

- `deterministic_contract`: required built-in tool surface is present with no duplicates
- `statistical_stability`: repeated tool-registry snapshots remain stable across N iterations
- `read_edit_workflow`: end-to-end read/edit/read tool workflow on a temp file

## CI Gate

Quality checks are wired in `.github/workflows/quality.yml` so pull requests fail when the quality harness fails.
The architecture dependency table in `docs/architecture_boundaries.md` is generated from the canonical policy in `LemonCore.Quality.ArchitecturePolicy`; refresh it with `mix lemon.architecture.docs`.
The platform-tier inventory in `docs/platform_tiers.md` is generated from `LemonCore.Quality.PlatformManifest`; refresh it with `mix lemon.platform.docs`.

Current hard gates include:

- `mix compile --warnings-as-errors`
- `mix test --cover --exclude integration`
- Vitest coverage runs for `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`
- `npm audit --omit=dev --audit-level=high` for shipped Node clients
- `mix lemon.quality`, duplicate-test checks, and eval harness runs
