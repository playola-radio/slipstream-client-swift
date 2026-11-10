#!/usr/bin/env bash
# Build Slipstream.app (Release, unsigned) into packaging/dist/, ready for
# sign-app.sh. Signing is a separate step so the build stays uncoupled from
# signing credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/packaging/dist"

cd "$REPO_ROOT"
xcodegen generate

echo "==> Building Slipstream.app (Release, unsigned)"
xcodebuild \
  -project SlipstreamViewer.xcodeproj \
  -scheme SlipstreamViewer \
  -configuration Release \
  -derivedDataPath "$REPO_ROOT/packaging/build/app" \
  -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT="$REPO_ROOT/packaging/build/app/Build/Products/Release/Slipstream.app"
[ -d "$BUILT" ] || { echo "error: build produced no .app at $BUILT" >&2; exit 1; }

DEST_APP="$DIST/Slipstream.app"
mkdir -p "$DIST"
rm -rf "$DEST_APP"
# ditto preserves the framework symlinks Sparkle relies on; cp would not.
/usr/bin/ditto "$BUILT" "$DEST_APP"
echo "==> Assembled: $DEST_APP"
