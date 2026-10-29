#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/direct-live.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

workspace="$tmp/workspace"
mkdir -p "$workspace/sub" "$tmp/config" "$tmp/data" "$tmp/state" "$tmp/cache"
printf 'alpha contents\n' > "$workspace/alpha.txt"
printf 'child contents\n' > "$workspace/sub/inside.txt"

run_smoke() {
  local map_default="$1"
  local expected="$2"
  local output

  if output=$(\
    XDG_DATA_HOME="$tmp/data" \
    XDG_CONFIG_HOME="$tmp/config" \
    XDG_STATE_HOME="$tmp/state" \
    XDG_CACHE_HOME="$tmp/cache" \
    DIRECT_LIVE_WORKSPACE="$workspace" \
    DIRECT_LIVE_SMOKE="$repo/tests/fixtures/live_smoke.lua" \
    DIRECT_LIVE_MAP_DEFAULT_KEYS="$map_default" \
    nvim --headless \
      -n -i NONE \
      -u "$repo/tests/fixtures/live_init.lua" \
      "$workspace" 2>&1); then
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
