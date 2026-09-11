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
    wget -q --show-progress -O "$destination" "$url" || return 1
  else
    die "Need curl or wget to download anything, and found neither."
  fi
}

# --- install ----------------------------------------------------------------

main() {
  asset="$(detect_asset)"
  url="$(download_url "$asset")"

  step "Installing $BINARY for $(uname -s) $(uname -m)"
  say "    from $url"

  temporary="$(mktemp)"
  trap 'rm -f "$temporary"' EXIT

  fetch "$url" "$temporary" || die "Download failed. If this is a brand-new checkout with no release yet, there is nothing to install."

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
