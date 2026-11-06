#!/usr/bin/env bash
# Notarize + staple a signed .app for Gatekeeper acceptance on clean Macs.
#
#   packaging/notarize-app.sh /path/to/SlipstreamViewer.app
#
# Requires a notarytool keychain profile:
#   xcrun notarytool store-credentials qie-notary \
#     --apple-id you@example.com --team-id FSRSPV9N9Q --password <app-specific-pw>
#   NOTARY_PROFILE=qie-notary packaging/notarize-app.sh App.app
# or an App Store Connect API key: NOTARY_KEY=<.p8 path> NOTARY_KEY_ID=… NOTARY_ISSUER=…
set -euo pipefail

APP="${1:?usage: notarize-app.sh /path/to/SlipstreamViewer.app}"
ZIP="${APP%.app}-notarize.zip"

# CI passes an App Store Connect API key; local releases use a keychain profile.
if [[ -n "${NOTARY_KEY:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER:?set NOTARY_ISSUER}")
else
  NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile) or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER}")
fi

echo "==> Zipping app for submission (ditto preserves signatures/symlinks)"
rm -f "$ZIP"
# Remove the transient zip on any exit (success or a failed notarytool/staple).
trap 'rm -f "$ZIP"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

echo "==> Stapling the ticket to the .app"
xcrun stapler staple "$APP"

echo "==> Validate staple + Gatekeeper assessment"
xcrun stapler validate "$APP"
spctl --assess --type exec -vvv "$APP"
echo "Notarized + stapled OK."
