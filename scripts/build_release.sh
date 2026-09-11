#!/usr/bin/env bash
#
# Builds a self-contained SMM Monitor release and packages it as a
# tarball ready to copy to a server.
#
#   ./scripts/build_release.sh            # build + package
#   ./scripts/build_release.sh --no-tar   # build only
#
# The output includes the Erlang runtime, so the target server needs
# neither Elixir nor Erlang installed — but it must be the same OS and
# architecture as the machine you build on (glibc-linked binaries are not
# portable across, say, Alpine and Ubuntu).

set -euo pipefail

cd "$(dirname "$0")/.."

APP="smm_monitor"
MIX_ENV="${MIX_ENV:-prod}"
export MIX_ENV

echo "==> Building ${APP} release (MIX_ENV=${MIX_ENV})"

# A stale _build can carry artefacts compiled against an older config,
# which is a miserable class of bug to debug on a server.
mix deps.get --only "$MIX_ENV"
mix compile
# Named explicitly: the project also defines a `standalone` (Burrito)
# release, and a bare `mix release` would try to build that too.
mix release smm_monitor --overwrite

RELEASE_DIR="_build/${MIX_ENV}/rel/${APP}"
VERSION=$("${RELEASE_DIR}/bin/${APP}" version | awk '{print $NF}')

echo "==> Built ${APP} ${VERSION} at ${RELEASE_DIR}"

if [ "${1:-}" = "--no-tar" ]; then
  exit 0
fi

mkdir -p dist
TARBALL="dist/${APP}-${VERSION}-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m).tar.gz"

tar -czf "$TARBALL" -C "$(dirname "$RELEASE_DIR")" "$(basename "$RELEASE_DIR")"

echo "==> Packaged $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo
echo "Copy it to the server with:"
echo "    scp $TARBALL deploy@your-server:/tmp/"
echo
echo "Then follow DEPLOY.md."
