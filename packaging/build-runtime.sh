#!/usr/bin/env bash
# Build the runtime the app embeds at Contents/Resources/SlipstreamRuntime: the daemon
# payload at the commit pinned in runtime.env, plus Node's bin/node, checked against
# its pinned sha256.
#
#   packaging/build-runtime.sh <out-dir>
#
# Needs git, curl and Node 24 with npm on PATH.
set -euo pipefail

OUT="${1:?usage: build-runtime.sh <out-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime.env
source "$HERE/runtime.env"

if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  echo "error: $OUT is not empty" >&2
  exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building the daemon payload at $DAEMON_REPO@$DAEMON_COMMIT"
git init -q "$WORK/daemon"
git -C "$WORK/daemon" fetch -q --depth 1 "https://github.com/$DAEMON_REPO.git" "$DAEMON_COMMIT"
git -C "$WORK/daemon" checkout -q FETCH_HEAD
(cd "$WORK/daemon" && npm ci && npm run build:payload -- --out "$OUT")

echo "==> Adding Node $NODE_VERSION"
NODE_DIST="node-v$NODE_VERSION-darwin-arm64"
curl -fsSLo "$WORK/$NODE_DIST.tar.xz" "https://nodejs.org/dist/v$NODE_VERSION/$NODE_DIST.tar.xz"
echo "$NODE_SHA256  $WORK/$NODE_DIST.tar.xz" | shasum -a 256 -c -
tar -xJf "$WORK/$NODE_DIST.tar.xz" -C "$WORK" "$NODE_DIST/bin/node"
mkdir -p "$OUT/bin"
install -m 755 "$WORK/$NODE_DIST/bin/node" "$OUT/bin/node"

[ "$("$OUT/bin/node" --version)" = "v$NODE_VERSION" ] || { echo "error: $OUT/bin/node is not v$NODE_VERSION" >&2; exit 1; }
for file in app/package.json app/dist/build-id app/dist/cli.js app/dist/mcp-forwarder.js; do
  [ -s "$OUT/$file" ] || { echo "error: payload has no $OUT/$file" >&2; exit 1; }
done
echo "==> Runtime: $OUT"
