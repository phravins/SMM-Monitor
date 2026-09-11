#!/usr/bin/env bash
#
# Proves a built binary actually runs, rather than merely existing.
#
# Two things get proved, because proving only the first one is what let a
# broken binary reach a user.
#
# 1. It boots. Started headless against throwaway directories, it should
#    unpack its payload, start the Erlang runtime, load the SQLite NIF,
#    run its migrations and read the client list.
#
# 2. It draws the dashboard. Started again under a pseudo-terminal with
#    the UI on, termbox should load and the dashboard should appear.
#
# The second phase exists because of a real failure. This script used to
# set SMM_TUI=0 and wait for "clients: monitoring" — a line the app logs
# *before* the terminal UI starts. A binary whose termbox library could
# not load passed this test and then died on the user's machine 24ms
# after printing the line the test was waiting for:
#
#     16:32:15.958 [info] clients: monitoring 1 client(s) ...
#     16:32:15.982 [warning] The on_load function for module
#       Elixir.ExTermbox.Bindings returned: ... __snprintf_chk: symbol not found
#
# Everything the test checked was working. The one thing it didn't check
# was the reason somebody downloads a dashboard.
set -euo pipefail

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

sandbox() {
  local phase="$1"

  export HOME="$workspace/$phase/home"
  export XDG_DATA_HOME="$workspace/$phase/data"
  export XDG_CONFIG_HOME="$workspace/$phase/config"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

  # Set, not defaulted. GitHub's runners export TERM=dumb, and termbox
  # cannot draw on a dumb terminal — it returns TB_EUNSUPPORTED_TERMINAL
  # and the app exits. The terminal here is a synthetic one this script
  # makes; naming it accurately is the point.
  export TERM=xterm-256color

  # Past the wizard: it is a separate thing to test, and it would sit
  # waiting for a keystroke that never comes.
  export SMM_SETUP_COMPLETE=1
}

fail() {
  echo "==> FAILED: $*"
  exit 1
}

# --- phase 1: does it boot ---------------------------------------------------

boots() {
  sandbox boot
  export SMM_TUI=0

  echo "==> booting $binary"
  "$binary" > "$workspace/boot.log" 2>&1 &
  local pid=$!

  # "clients: monitoring N client(s)" is the last thing boot logs.
  #
  # Waiting for the *database file* instead is a race, and it cost a red
  # build to learn: SQLite creates the file before the migrations finish
  # and well before the client list is read.
  local _
  for _ in $(seq 1 60); do
    grep -q "clients: monitoring" "$workspace/boot.log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo "--- output"
  cat "$workspace/boot.log"

  [ -f "$XDG_DATA_HOME/smm_monitor/mentions.db" ] ||
    fail "it never created its database"

  grep -qE "Migrated|Migrations already up" "$workspace/boot.log" ||
    fail "it never ran its migrations"

  grep -q "clients: monitoring" "$workspace/boot.log" ||
    fail "it never finished starting (no client list read)"

  echo "==> booted, migrated and opened its database"
}

# --- phase 2: does it draw ---------------------------------------------------

# CI has no terminal, so one gets made. `script` is the portable way to
# put a process on a pseudo-terminal, and the two spellings are not
# compatible: util-linux takes the command with -c, BSD (which is what
# macOS has) takes it as trailing arguments.
under_a_terminal() {
  local log="$1" command="$2"

  # A pty created with no terminal behind it is 0x0, and a dashboard has
  # nowhere to draw. `stty` sizes it from the inside, which is the only
  # place either spelling of `script` lets you.
  local sized="stty rows 40 cols 120 2>/dev/null; exec $command"

  if script --version 2>&1 | grep -q util-linux; then
    script -qec "$sized" "$log"
  else
    script -q "$log" /bin/sh -c "$sized"
  fi
}

draws() {
  sandbox draw
  unset SMM_TUI  # the binary turns the dashboard on by itself

  echo "==> drawing the dashboard"

  under_a_terminal "$workspace/tty.log" "$binary" >/dev/null 2>&1 &
  local pid=$!

  # Long enough to unpack, boot and render a frame; the dashboard redraws
  # on a timer, so a frame is not something to race for.
  sleep 25

  local alive=yes
  kill -0 "$pid" 2>/dev/null || alive=no
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Terminal output is escape codes and NULs; make it greppable.
  local screen="$workspace/screen.txt"
  tr -d '\000' < "$workspace/tty.log" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > "$screen"

  echo "--- what appeared on screen (first 2KB)"
  head -c 2000 "$screen"
  echo
  # Whatever went wrong is at the end, and truncating to the first 2KB is
  # how a CI log ends up showing a successful migration and no reason.
  echo "--- and the last 2KB"
  tail -c 2000 "$screen"
  echo

  # The app's own diagnosis, when it managed to make one. Preferred over
  # the greps below because it is the same sentence the user would read.
  if grep -q "could not start the dashboard" "$screen"; then
    fail "it refused to start the dashboard (see its explanation above)"
  fi

  # The specific way this breaks: a NIF built for the wrong libc.
  if grep -qE "symbol not found|load_failed|NIF library" "$screen"; then
    echo "--- the library that would not load:"
    grep -oE "Failed to load NIF library.{0,160}" "$screen" | head -3
    fail "the dashboard's terminal library would not load"
  fi

  # `if`, not `grep && fail`: under `set -e` an AND-list that ends false
  # is itself a failed command, so the happy path would abort the script.
  if grep -q "Kernel pid terminated" "$screen"; then
    fail "the runtime terminated"
  fi

  [ "$alive" = yes ] || fail "it exited instead of showing a dashboard"

  # Panel titles from the dashboard itself. Without this the test would
  # pass on a process that sat there drawing nothing at all.
  if ! grep -qE "Mentions|Sentiment" "$screen"; then
    fail "it stayed up but drew no dashboard"
  fi

  echo "==> drew the dashboard"
}

boots
draws

echo "==> OK: it boots, and it draws"
