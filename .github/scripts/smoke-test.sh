#!/usr/bin/env bash
#
# Proves a built binary actually runs, rather than merely existing.
#
# Starts it headless against throwaway directories and waits for the line
# that means the supervision tree is up — by which point the payload has
# unpacked, the Erlang runtime has started, the SQLite NIF has loaded and
# the migrations have run. The terminal UI is the one part this can't
# reach: CI has no terminal to draw on.
#
# Waiting for the *database file* instead is a race, and it cost a red
# build to learn: SQLite creates the file before the migrations finish
# and well before the client list is read, so on a fast machine this
# killed the app mid-boot and then complained the boot was incomplete.
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

# "clients: monitoring N client(s)" is the last thing boot logs, so it is
# the signal that everything before it worked.
for _ in $(seq 1 60); do
  if grep -q "clients: monitoring" "$workspace/out.log" 2>/dev/null; then
    break
  fi

  # Stop waiting the moment it dies — no sense burning a minute on a
  # process that already gave up.
  if ! kill -0 "$pid" 2>/dev/null; then
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

if ! grep -qE "Migrated|Migrations already up" "$workspace/out.log"; then
  echo "==> FAILED: it never ran its migrations"
  exit 1
fi

if ! grep -q "clients: monitoring" "$workspace/out.log"; then
  echo "==> FAILED: it never finished starting (no client list read)"
  exit 1
fi

echo "==> OK: unpacked, started, migrated and opened its database"
