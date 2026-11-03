#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/direct-live.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

workspace="$tmp/workspace"
mkdir -p "$workspace/sub" "$tmp/config" "$tmp/data" "$tmp/state" "$tmp/cache"
printf 'alpha contents\n' > "$workspace/alpha.txt"
printf 'child contents\n' > "$workspace/sub/inside.txt"

run_smoke() {
  local map_default="$1"
  local expected="$2"
  local output
  local native_workspace native_smoke
  native_workspace=$(native_path "$workspace")
  native_smoke=$(native_path "$repo/tests/fixtures/live_smoke.lua")

  if output=$(\
    XDG_DATA_HOME="$(native_path "$tmp/data")" \
    XDG_CONFIG_HOME="$(native_path "$tmp/config")" \
    XDG_STATE_HOME="$(native_path "$tmp/state")" \
    XDG_CACHE_HOME="$(native_path "$tmp/cache")" \
    DIRECT_LIVE_WORKSPACE="$native_workspace" \
    DIRECT_LIVE_SMOKE="$native_smoke" \
    DIRECT_LIVE_MAP_DEFAULT_KEYS="$map_default" \
    nvim --headless \
      -n -i NONE \
      -u "$(native_path "$repo/tests/fixtures/live_init.lua")" \
      "$native_workspace" 2>&1); then
    printf '%s\n' "$output"
  else
    local status=$?
    printf '%s\n' "$output" >&2
    printf 'real-startup smoke test failed (nvim exit %d)\n' "$status" >&2
    exit "$status"
  fi

  if [[ "$output" != *"$expected"* ]]; then
    printf 'real-startup smoke test did not report %s\n' "$expected" >&2
    exit 1
  fi
}

run_smoke true LIVE_STARTUP_OK
run_smoke false LIVE_STARTUP_OPTOUT_OK
