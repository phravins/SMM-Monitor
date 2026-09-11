#!/usr/bin/env bash
#
# Builds one downloadable binary.
#
#     scripts/build-standalone.sh linux
#     scripts/build-standalone.sh macos
#
# Targets: linux, linux_arm, macos, macos_intel. Needs `zig` and `xz` on
# PATH; everything else it does itself.
#
# Why this exists rather than a plain `mix release standalone`:
#
# Burrito rebuilds NIFs for the target it is packaging, and expects the
# rebuilt library to land in `$MIX_APP_PATH/priv` — the modern
# elixir_make convention, which exqlite follows. ex_termbox predates it
# and writes to its own `priv/` instead, so Burrito's copy finds nothing
# and the binary ends up carrying whatever the *host* compiled earlier.
# On Linux that means a glibc library inside a musl runtime, and the
# dashboard dies on startup with
#
#     Failed to load NIF library: ... __snprintf_chk: symbol not found
#
# — a build that succeeds and a binary that doesn't run. So the NIFs are
# compiled for the target *first*, into the directory the release
# actually copies from, and the native ones are put back afterwards so
# the next `mix test` isn't linking against a foreign libc.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-linux}"

case "$TARGET" in
  linux) TRIPLE="x86_64-linux" ;;
  linux_arm) TRIPLE="aarch64-linux" ;;
  macos) TRIPLE="aarch64-macos" ;;
  macos_intel) TRIPLE="x86_64-macos" ;;
  *)
    echo "Unknown target: $TARGET (linux, linux_arm, macos, macos_intel)" >&2
    exit 1
    ;;
esac

# The deps with native code in them. Both get built twice: once for the
# target, once to put the host's own back.
NIF_DEPS=(ex_termbox exqlite)

export MIX_ENV=prod
export BURRITO_TARGET="$TARGET"

# A production build, in its own build directory. The NIFs compiled here
# are for another libc, and `_build/prod` is where the *server* release
# is assembled from on the same machine — the two sharing a directory is
# all it takes to leave a systemd install with a termbox library it
# cannot load ("invalid ELF header"). Burrito, meanwhile, insists on
# MIX_ENV=prod: anything else gets a debug wrapper four times the size.
export MIX_BUILD_PATH="$(pwd)/_build/standalone"

# ex_termbox's Makefile is timestamp-driven and its output lives in the
# dep's own priv/, which every environment shares. So a rebuild has to
# start from `make clean` — without it `make` looks at a library newer
# than its sources, decides there is nothing to do, and the last
# machine's libc quietly wins.
compile_nifs() {
  (cd deps/ex_termbox && make clean >/dev/null 2>&1) || true
  mix deps.compile "${NIF_DEPS[@]}" --force
}

# The cross-compiled libraries must not outlive this script: `mix test`
# on this machine would load one and fail on a foreign libc.
restore_native_nifs() {
  echo "==> restoring native NIFs"
  env -u CC -u BURRITO_CC_TARGET -u MIX_BUILD_PATH MIX_ENV=dev bash -c \
    'cd deps/ex_termbox && make clean >/dev/null 2>&1; cd ../.. && mix deps.compile ex_termbox exqlite --force >/dev/null'
}

trap restore_native_nifs EXIT

echo "==> fetching and compiling dependencies for $MIX_ENV"
mix deps.get
mix deps.compile

echo "==> building NIFs for $TRIPLE"
export CC="$(pwd)/scripts/burrito-cc"
export BURRITO_CC_TARGET="$TRIPLE"
compile_nifs
unset CC BURRITO_CC_TARGET

echo "==> packaging $TARGET"
mix release standalone --overwrite

binary="burrito_out/standalone_${TARGET}"

if [ ! -f "$binary" ]; then
  echo "==> FAILED: expected $binary" >&2
  exit 1
fi

echo "==> built $binary"
file "$binary"
ls -lh "$binary"
