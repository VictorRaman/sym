#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/mix_isolated.sh [--cwd PATH] [--build-root PATH] [--min-elixir VERSION] [--toolchain-bin PATH] [--keep-build-root] [--] <mix args...>

Examples:
  scripts/mix_isolated.sh --cwd apps/lemon_mesh -- test test/lemon_mesh/handoff_store_test.exs
  scripts/mix_isolated.sh --cwd apps/lemon_control_plane -- test test/lemon_control_plane/methods/agent_chat_methods_test.exs
  scripts/mix_isolated.sh --toolchain-bin "$HOME/.elixir-install/installs/elixir/1.19.5-otp-27/bin" -- compile --warnings-as-errors
  scripts/mix_isolated.sh -- compile --warnings-as-errors

What it does:
  - checks that the installed Elixir version meets the required minimum
  - creates an isolated MIX_BUILD_ROOT / REBAR_BASE_DIR / XDG_CACHE_HOME by default
  - can auto-select a newer local ~/.elixir-install toolchain when PATH is too old
  - runs the requested mix command from the selected working directory
  - preserves the isolated build root automatically when the mix command fails
EOF
}

require_elixir="1.19.0"
cwd=""
build_root=""
keep_build_root=0
toolchain_bins=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)
      cwd="$2"
      shift 2
      ;;
    --build-root)
      build_root="$2"
      shift 2
      ;;
    --min-elixir)
      require_elixir="$2"
      shift 2
      ;;
    --keep-build-root)
      keep_build_root=1
      shift
      ;;
    --toolchain-bin)
      toolchain_bins+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

if [[ -n "${LEMON_MIX_TOOLCHAIN_BIN:-}" ]]; then
  toolchain_bins+=("${LEMON_MIX_TOOLCHAIN_BIN}")
fi

prepend_toolchain_bins() {
  local bin_path

  for bin_path in "$@"; do
    if [[ -n "$bin_path" && -d "$bin_path" ]]; then
      PATH="$bin_path:$PATH"
    fi
  done

  export PATH
}

detect_elixir_version() {
  "$1" -e 'IO.write(System.version())' 2>/dev/null
}

version_ok() {
  "$1" -e '
    normalize = fn version ->
      version
      |> String.split(".")
      |> Enum.take(3)
      |> Enum.map(&String.to_integer/1)
      |> then(fn parts -> parts ++ List.duplicate(0, max(0, 3 - length(parts))) end)
      |> Enum.take(3)
      |> List.to_tuple()
    end

    required = normalize.(System.argv() |> Enum.at(0))
    installed = normalize.(System.version())

    if installed >= required, do: IO.write("ok"), else: IO.write("too_old")
  ' "$require_elixir"
}

resolve_mix_toolchain() {
  local elixir_path=""
  local mix_path=""

  if command -v elixir >/dev/null 2>&1; then
    elixir_path="$(command -v elixir)"
  fi

  if command -v mix >/dev/null 2>&1; then
    mix_path="$(command -v mix)"
  fi

  printf '%s\n%s\n' "$elixir_path" "$mix_path"
}

append_latest_local_toolchain() {
  local home_dir="${HOME:-}"
  local elixir_root=""
  local otp_root=""
  local latest_elixir_bin=""
  local latest_otp_bin=""

  [[ -n "$home_dir" ]] || return 1

  elixir_root="$home_dir/.elixir-install/installs/elixir"
  otp_root="$home_dir/.elixir-install/installs/otp"

  if [[ -d "$elixir_root" ]]; then
    latest_elixir_bin="$(
      find "$elixir_root" -mindepth 2 -maxdepth 2 -path '*/bin' 2>/dev/null \
        | sort -V \
        | tail -n 1
    )"
  fi

  if [[ -d "$otp_root" ]]; then
    latest_otp_bin="$(
      find "$otp_root" -mindepth 2 -maxdepth 2 -path '*/bin' 2>/dev/null \
        | sort -V \
        | tail -n 1
    )"
  fi

  if [[ -n "$latest_elixir_bin" ]]; then
    if [[ -n "$latest_otp_bin" ]]; then
      prepend_toolchain_bins "$latest_elixir_bin" "$latest_otp_bin"
    else
      prepend_toolchain_bins "$latest_elixir_bin"
    fi

    return 0
  fi

  return 1
}

prepend_toolchain_bins "${toolchain_bins[@]}"

mapfile -t resolved_toolchain < <(resolve_mix_toolchain)
elixir_cmd="${resolved_toolchain[0]:-}"
mix_cmd="${resolved_toolchain[1]:-}"

if [[ -z "$elixir_cmd" || -z "$mix_cmd" ]]; then
  echo "error: elixir/mix are not installed or not on PATH" >&2
  exit 69
fi

installed_elixir="$(detect_elixir_version "$elixir_cmd")"

if [[ -z "$installed_elixir" ]]; then
  echo "error: failed to detect Elixir version" >&2
  exit 70
fi

if [[ "$(version_ok "$elixir_cmd")" != "ok" ]]; then
  current_elixir_cmd="$elixir_cmd"

  if append_latest_local_toolchain; then
    mapfile -t resolved_toolchain < <(resolve_mix_toolchain)
    elixir_cmd="${resolved_toolchain[0]:-}"
    mix_cmd="${resolved_toolchain[1]:-}"
    installed_elixir="$(detect_elixir_version "$elixir_cmd")"

    if [[ "$elixir_cmd" != "$current_elixir_cmd" ]]; then
      echo "mix_isolated: auto-selected toolchain elixir=$elixir_cmd mix=$mix_cmd" >&2
    fi
  fi
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cwd="${cwd:-$repo_root}"

if [[ ! -d "$cwd" ]]; then
  echo "error: working directory does not exist: $cwd" >&2
  exit 66
fi

version_check="$(version_ok "$elixir_cmd")"

if [[ "$version_check" != "ok" ]]; then
  echo "error: Elixir $require_elixir+ is required, but this machine has $installed_elixir" >&2
  echo "hint: update the toolchain before relying on fresh verification evidence" >&2
  exit 65
fi

autogenerated_build_root=0
if [[ -z "$build_root" ]]; then
  build_root="$(mktemp -d "${TMPDIR:-/tmp}/lemon-mix-isolated.XXXXXX")"
  autogenerated_build_root=1
else
  mkdir -p "$build_root"
fi

export MIX_BUILD_ROOT="$build_root"
export REBAR_BASE_DIR="${REBAR_BASE_DIR:-$build_root/rebar}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$build_root/xdg}"

cleanup() {
  status=$?

  if [[ $status -eq 0 && $keep_build_root -eq 0 && $autogenerated_build_root -eq 1 ]]; then
    rm -rf "$build_root"
  else
    echo "mix_isolated: preserved build root at $build_root" >&2
  fi

  exit "$status"
}

trap cleanup EXIT

echo "mix_isolated: cwd=$cwd" >&2
echo "mix_isolated: MIX_BUILD_ROOT=$MIX_BUILD_ROOT" >&2
echo "mix_isolated: REBAR_BASE_DIR=$REBAR_BASE_DIR" >&2
echo "mix_isolated: XDG_CACHE_HOME=$XDG_CACHE_HOME" >&2
echo "mix_isolated: elixir=$installed_elixir" >&2
echo "mix_isolated: elixir_bin=$elixir_cmd" >&2
echo "mix_isolated: mix_bin=$mix_cmd" >&2
echo "mix_isolated: running mix $*" >&2

cd "$cwd"
"$mix_cmd" "$@"
