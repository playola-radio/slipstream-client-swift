#!/usr/bin/env bash
# Notarize + staple a signed .app for Gatekeeper acceptance on clean Macs.
#
#   packaging/notarize-app.sh /path/to/SlipstreamViewer.app
#
# Requires a notarytool keychain profile:
#   xcrun notarytool store-credentials qie-notary \
#     --apple-id you@example.com --team-id FSRSPV9N9Q --password <app-specific-pw>
#   NOTARY_PROFILE=qie-notary packaging/notarize-app.sh App.app
set -euo pipefail

APP="${1:?usage: notarize-app.sh /path/to/SlipstreamViewer.app}"
ZIP="${APP%.app}-notarize.zip"

NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"

echo "==> Zipping app for submission (ditto preserves signatures/symlinks)"
rm -f "$ZIP"
# Remove the transient zip on any exit (success or a failed notarytool/staple).
trap 'rm -f "$ZIP"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket to the .app"
xcrun stapler staple "$APP"

echo "==> Validate staple + Gatekeeper assessment"
xcrun stapler validate "$APP"
spctl --assess --type exec -vvv "$APP"
echo "Notarized + stapled OK."
