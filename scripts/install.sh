#!/bin/sh
#
# SMM Monitor installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/phravins/SMM-Monitor/main/scripts/install.sh | sh
#
# Works out which binary this machine needs, fetches it from the latest
# release, and puts it somewhere on your PATH. No Elixir, no Erlang, no
# build step — the binary carries its own runtime.
#
# Knobs, for the people who want them:
#
#   SMM_INSTALL_DIR=/usr/local/bin   where to install (default ~/.local/bin)
#   SMM_VERSION=v0.2.0               a specific release (default: latest)
#   SMM_ASSET_URL=https://...        download from somewhere else entirely
#                                    (a mirror, or a binary you built)
#
set -eu

REPO="phravins/SMM-Monitor"
BINARY="smm-monitor"
INSTALL_DIR="${SMM_INSTALL_DIR:-$HOME/.local/bin}"

# --- say things -------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }

die() {
  printf '\033[31mx\033[0m %s\n' "$*" >&2
  exit 1
}

# --- which binary does this machine need ------------------------------------

detect_asset() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os_name="macos" ;;
    Linux) os_name="linux" ;;
    MINGW* | MSYS* | CYGWIN*)
      die "This is the macOS and Linux installer. On Windows, see the PowerShell one-liner in the README."
      ;;
    *) die "Unsupported operating system: $os" ;;
  esac

  case "$arch" in
    x86_64 | amd64) arch_name="x86_64" ;;
    arm64 | aarch64) arch_name="arm64" ;;
    *) die "Unsupported architecture: $arch (we publish x86_64 and arm64)" ;;
  esac

  printf '%s-%s-%s' "$BINARY" "$os_name" "$arch_name"
}

# --- fetch ------------------------------------------------------------------

download_url() {
  asset="$1"

  if [ -n "${SMM_ASSET_URL:-}" ]; then
    printf '%s' "$SMM_ASSET_URL"
  elif [ -n "${SMM_VERSION:-}" ]; then
    printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$SMM_VERSION" "$asset"
  else
    # GitHub redirects this to whatever the newest release is, which
    # saves parsing JSON in a shell script.
    printf 'https://github.com/%s/releases/latest/download/%s' "$REPO" "$asset"
  fi
}

fetch() {
  url="$1"
  destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$destination" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    # No --show-progress: it is GNU wget only, and recent enough GNU
    # wget at that.
    wget -O "$destination" "$url" || return 1
  else
    die "Need curl or wget to download anything, and found neither."
  fi
}

# --- clear any stale unpacked copy ------------------------------------------

# The binary carries its runtime compressed inside it and unpacks it on
# first run into a directory named after the app and Erlang versions.
# Burrito decides whether to unpack by looking for a metadata file there
# and nothing else, so a directory left by an earlier build of the same
# version is reused forever — and installing again does not replace it.
#
# That is not a hypothetical. A copy built on an ordinary Linux machine
# holds glibc-linked libraries, the bundled runtime is musl, and the
# dashboard dies on startup with
#
#     Failed to load NIF library: ... __snprintf_chk: symbol not found
#
# every time, no matter how often you reinstall. So the installer clears
# it: the freshly installed binary then unpacks what it is carrying.
#
# Only the unpacked program lives there. The database and the settings
# file are elsewhere and are not touched.
payload_base() {
  if [ -n "${STANDALONE_INSTALL_DIR:-}" ]; then
    printf '%s/.burrito' "$STANDALONE_INSTALL_DIR"
  elif [ "$(uname -s)" = "Darwin" ]; then
    printf '%s/Library/Application Support/.burrito' "$HOME"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then
    printf '%s/.burrito' "$XDG_DATA_HOME"
  else
    printf '%s/.local/share/.burrito' "$HOME"
  fi
}

clear_stale_payload() {
  base="$(payload_base)"

  [ -d "$base" ] || return 0

  cleared=0

  # `standalone` is this release's name, and the only thing this script
  # is entitled to delete. Another Burrito app's directory is left alone.
  for unpacked in "$base"/standalone_erts-*; do
    [ -d "$unpacked" ] || continue

    if rm -rf "$unpacked"; then
      cleared=1
    else
      warn "Could not remove $unpacked"
      say "    If the dashboard won't start, delete that folder by hand."
    fi
  done

  # An `if`, not `test && step`: under `set -e` an AND-list that ends
  # false is a failed command, and "nothing to clear" would abort the
  # install.
  if [ "$cleared" -eq 1 ]; then
    step "Cleared the previous unpacked copy"
  fi

  return 0
}

# --- install ----------------------------------------------------------------

main() {
  asset="$(detect_asset)"
  url="$(download_url "$asset")"

  step "Installing $BINARY for $(uname -s) $(uname -m)"
  say "    from $url"

  # An explicit template, because macOS's mktemp refuses a bare call —
  # the installer would die on the Mac it was meant to serve.
  temporary="$(mktemp "${TMPDIR:-/tmp}/smm-monitor.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT

  if ! fetch "$url" "$temporary"; then
    say ""
    die "$(cat <<MESSAGE
Couldn't download $asset.

Most likely there is no published release yet — the download only
appears once a version has been tagged. Check what's available at

    https://github.com/$REPO/releases

If a release is listed there and this still fails, it is worth opening
an issue: that would mean the file is missing from it.
MESSAGE
)"
  fi

  # A 404 page is still a successful download as far as curl -f is
  # concerned on some versions, so check we got something binary-sized.
  size="$(wc -c < "$temporary" | tr -d ' ')"
  [ "$size" -gt 1000000 ] || die "That download looks wrong ($size bytes). Check that $asset exists on the release page."

  mkdir -p "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"

  target="$INSTALL_DIR/$BINARY"
  chmod 755 "$temporary"

  # Move rather than copy-over: replacing a running binary in place is
  # how you get "text file busy" on Linux.
  mv -f "$temporary" "$target" || die "Could not write $target"
  trap - EXIT

  step "Installed to $target"

  clear_stale_payload

  case ":$PATH:" in
    *":$INSTALL_DIR:"*)
      say ""
      step "Run it:"
      say ""
      say "    $BINARY"
      say ""
      ;;
    *)
      warn "$INSTALL_DIR is not on your PATH."
      say ""
      say "Run it with the full path:"
      say ""
      say "    $target"
      say ""
      say "Or add the directory to your PATH — for the current shell:"
      say ""
      say "    export PATH=\"$INSTALL_DIR:\$PATH\""
      say ""
      say "and to keep it, add that line to ~/.zshrc or ~/.bashrc."
      say ""
      ;;
  esac

  say "First run asks a couple of questions on screen; there is nothing to"
  say "edit and no API key required to look around."
}

main "$@"
