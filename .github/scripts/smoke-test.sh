#!/usr/bin/env bash
#
# Proves a built binary actually runs, rather than merely existing.
#
# Starts it headless against throwaway directories, gives it a few
# seconds, and checks it got far enough to create its database — which
# means the payload unpacked, the Erlang runtime started, the SQLite NIF
# loaded and the migrations ran. The terminal UI is the one part this
# can't reach: CI has no terminal to draw on.
set -euo pipefail

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

export HOME="$workspace/home"
export XDG_DATA_HOME="$workspace/data"
export XDG_CONFIG_HOME="$workspace/config"
export SMM_TUI=0
export SMM_SETUP_COMPLETE=1
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

echo "==> running $binary"
"$binary" > "$workspace/out.log" 2>&1 &
pid=$!

database="$XDG_DATA_HOME/smm_monitor/mentions.db"

for _ in $(seq 1 60); do
  if [ -f "$database" ]; then
    break
  fi
  sleep 1
done

kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

echo "==> output"
cat "$workspace/out.log"

if [ ! -f "$database" ]; then
  echo "==> FAILED: the binary never created its database"
  exit 1
fi

for needle in "Migrated" "monitoring"; do
  if ! grep -q "$needle" "$workspace/out.log"; then
    echo "==> FAILED: expected '$needle' in the output"
    exit 1
  fi
done

echo "==> OK: unpacked, started, migrated and opened its database"
