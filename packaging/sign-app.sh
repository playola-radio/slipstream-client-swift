#!/usr/bin/env bash
# Inside-out Developer ID + hardened-runtime signing.
#
#   packaging/sign-app.sh packaging/dist/SlipstreamViewer.app
#
# Signs Sparkle's nested helpers, then embedded frameworks, then the app. `--deep`
# is used only to verify, never to sign: it applies one identity/entitlement set
# indiscriminately and skips already-signed code.
#
# Override the identity with SIGN_IDENTITY=... (defaults to Playola Developer ID).
set -euo pipefail

APP="${1:?usage: sign-app.sh /path/to/SlipstreamViewer.app}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
TEAM_ID="FSRSPV9N9Q"

if [[ "$(security find-identity -v -p codesigning)" != *"$IDENTITY"* ]]; then
  echo "error: signing identity not found in keychain: $IDENTITY" >&2
  exit 1
fi

sign() { # <path> [extra codesign args...]
  local path="$1"
  shift
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" "$path"
}

# Sparkle 2 nests an Autoupdate executable, an Updater.app and XPC services inside
# Sparkle.framework. Signing only the framework leaves them ad-hoc, which fails
# notarization and breaks Sparkle's installer. Versions/B is Sparkle 2.9.6's layout;
# re-check it when Sparkle is bumped.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "error: Sparkle.framework missing from $APP" >&2; exit 1; }
echo "==> Signing Sparkle nested helpers (inside-out)"
for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
  [ -e "$xpc" ] && sign "$xpc" --preserve-metadata=entitlements
done
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE/Versions/B/Autoupdate"

echo "==> Signing embedded frameworks/dylibs"
while IFS= read -r fw; do
  [ -n "$fw" ] && sign "$fw"
done < <(find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) | sort -r)

echo "==> Signing the app (outermost)"
sign "$APP"

echo "==> Guard: every Mach-O must be signed by team $TEAM_ID"
# `file` adds a pseudo-path line per slice of a universal binary (Sparkle ships
# x86_64+arm64); the real-file test drops those.
unsigned=0
while IFS= read -r macho; do
  [ -f "$macho" ] || continue
  # Capture first: under pipefail, `grep -q` exiting early SIGPIPEs codesign.
  if [[ "$(codesign -dvvv "$macho" 2>&1)" != *"TeamIdentifier=$TEAM_ID"* ]]; then
    echo "   UNSIGNED/wrong-team: $macho" >&2
    unsigned=$((unsigned + 1))
  fi
done < <(find "$APP" -type f -print0 | xargs -0 file 2>/dev/null \
           | grep 'Mach-O' | cut -d: -f1 | sort -u)
[ "$unsigned" -eq 0 ] || { echo "error: $unsigned Mach-O binaries not properly signed" >&2; exit 1; }

echo "==> Verify (codesign --verify --strict --deep)"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|Identifier=|Runtime" || true
echo "Signed OK. Next: packaging/notarize-app.sh \"$APP\""
