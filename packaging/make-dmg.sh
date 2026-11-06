#!/usr/bin/env bash
# Build a DMG from the signed, notarized app, then sign, notarize and staple the DMG.
#
#   packaging/make-dmg.sh   (reads versions from the app's Info.plist)
#
# Gatekeeper checks the outermost container the user opens, so the DMG is signed and
# notarized too; stapling lets it validate offline. The filename carries both the
# marketing version and the integer build so two builds of one marketing version
# never overwrite each other in S3. hdiutil, not create-dmg: create-dmg drives Finder
# over AppleEvents and times out when the release runs headless.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/packaging/dist"
APP="$DIST/SlipstreamViewer.app"
[ -d "$APP" ] || { echo "error: no app at $APP (run build/sign/notarize first)" >&2; exit 1; }
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/SlipstreamViewer-$SHORT-$BUILD.dmg"
rm -f "$DMG"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/slipstream-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/SlipstreamViewer.app"
ln -s /Applications "$STAGE/Applications"
echo "==> Building DMG: $(basename "$DMG")"
hdiutil create -volname "Slipstream $SHORT" \
  -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "==> Signing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "==> DMG: $DMG"
