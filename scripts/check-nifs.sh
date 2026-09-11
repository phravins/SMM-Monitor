#!/usr/bin/env bash
#
#     scripts/check-nifs.sh <target>
#
# Looks at the native libraries a release is about to be packed from and
# fails if any of them was built for the wrong machine.
#
# Why this exists
#
# The Erlang runtime inside these binaries is linked against musl. The
# machine doing the building is not: an ordinary Linux box links against
# glibc, so a library compiled by its own `cc` is a glibc library. Load
# one from a musl runtime and it dies on the first fortified libc symbol
# it needs:
#
#     Failed to load NIF library: ... __snprintf_chk: symbol not found
#
# Nothing about this is visible at build time. The compile succeeds, the
# release assembles, the binary is the right size and starts normally —
# and then the dashboard won't draw, on the user's machine, after they
# downloaded it.
#
# `scripts/build-standalone.sh` cross-compiles the NIFs to stop that
# happening. This checks that it worked, which is a different question,
# and the one that was never asked: ex_termbox writes its library to its
# own priv/ rather than the one elixir_make nominates, so a step going
# quietly wrong leaves the host's copy in place and everything downstream
# looks fine.
#
# Only the two libraries this project builds are checked. Erlang's own
# native libraries — crypto, asn1, runtime_tools — are staged here as the
# *host's* copies and swapped for the bundled runtime's when Burrito
# packs the binary, so reading them here says nothing about what ships.
# Compare a staged tree with the payload out of a published binary and
# they differ exactly so.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-linux}"
STAGE="${MIX_BUILD_PATH:-$(pwd)/_build/standalone}/rel/standalone/lib"

# The deps with native code of our own: the dashboard's terminal library
# and SQLite. Both are compiled by the build script for the target.
OURS=(ex_termbox exqlite)

case "$TARGET" in
  linux) want_kind=elf; want_arch="x86-64" ;;
  linux_arm) want_kind=elf; want_arch="aarch64" ;;
  macos) want_kind=macho; want_arch="arm64" ;;
  macos_intel) want_kind=macho; want_arch="x86_64" ;;
  *) echo "Unknown target: $TARGET" >&2; exit 1 ;;
esac

[ -d "$STAGE" ] || { echo "==> nothing staged at $STAGE" >&2; exit 1; }

problems=0
checked=0

complain() {
  problems=$((problems + 1))
  echo "    x $1"
}

libraries() {
  local dep
  for dep in "${OURS[@]}"; do
    find "$STAGE"/"$dep"-*/priv -type f \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null
  done | sort
}

echo "==> checking staged native libraries for $TARGET"

# A dependency staged with no native library at all is its own kind of
# broken, and must not read as success just because nothing was examined.
for dep in "${OURS[@]}"; do
  if [ -z "$(find "$STAGE"/"$dep"-*/priv -type f \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null)" ]; then
    echo "==> FAILED: $dep staged no native library under $STAGE" >&2
    exit 1
  fi
done

# Both extensions: macOS builds of some deps produce .dylib, and Erlang's
# own drivers live a directory deeper than the NIFs do.
while IFS= read -r library; do
  checked=$((checked + 1))
  description="$(file -b "$library")"
  name="${library#"$STAGE/"}"

  case "$want_kind" in
    elf)
      case "$description" in
        *ELF*) : ;;
        *) complain "$name is not an ELF object: $description"; continue ;;
      esac

      case "$description" in
        *"$want_arch"*) : ;;
        *) complain "$name is built for the wrong architecture: $description" ;;
      esac

      # The tell. A musl-linked library has no versioned glibc symbols
      # and asks for "libc.so"; a glibc one asks for "libc.so.6" and
      # carries @GLIBC_ versions on the symbols it imports.
      if nm -D --undefined-only "$library" 2>/dev/null | grep -q '@GLIBC_'; then
        offenders="$(nm -D --undefined-only "$library" | grep -o '[^ ]*@GLIBC_[0-9.]*' | head -3 | tr '\n' ' ')"
        complain "$name is linked against glibc, but the bundled runtime is musl: $offenders"
      elif readelf -d "$library" 2>/dev/null | grep -q 'Shared library: \[libc\.so\.6\]'; then
        complain "$name needs glibc's libc.so.6, but the bundled runtime is musl"
      fi
      ;;

    macho)
      # Nothing on a Linux runner reads Mach-O symbol tables, so this is
      # what there is: the right format for the right processor. A
      # cross-compile that silently fell back to the host produces an ELF
      # file here, which is the failure worth catching.
      case "$description" in
        *Mach-O*"$want_arch"*) : ;;
        *) complain "$name is not a $want_arch Mach-O object: $description" ;;
      esac
      ;;
  esac
done < <(libraries)

if [ "$problems" -gt 0 ]; then
  # Problems, not libraries: one library can be both the wrong
  # architecture and linked against the wrong libc.
  echo "==> FAILED: $problems problem(s) across $checked native libraries; they would not load on the target" >&2
  echo "    Build through scripts/build-standalone.sh, which cross-compiles them." >&2
  exit 1
fi

echo "==> OK: all $checked native libraries match $TARGET"
