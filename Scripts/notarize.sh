#!/bin/bash
# Notarize the Developer ID-signed .app and staple the ticket to it.
# Required for distribution outside the App Store (DMG/zip to end users)
# so that Gatekeeper doesn't block it on first launch.
#
# Prerequisites:
#   1. Paid Apple Developer Program account
#   2. Developer ID Application certificate in Keychain
#   3. App-specific password stored in Keychain profile "notarize-sasha":
#        xcrun notarytool store-credentials notarize-sasha \
#          --apple-id "$APPLE_ID" \
#          --team-id  "$TEAM_ID" \
#          --password "$APP_SPECIFIC_PASSWORD"
#
# Usage:
#   ./Scripts/build.sh developerid
#   ./Scripts/notarize.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/SashaSwitcher.app"
ZIP_PATH="$PROJECT_DIR/build/SashaSwitcher.zip"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-notarize-sasha}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "✗ Build .app first: ./Scripts/build.sh developerid"
    exit 1
fi

echo "[1/4] Zipping for submission..."
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "[2/4] Submitting to Apple notary service (may take 2–10 min)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "[3/4] Stapling notarization ticket to .app..."
xcrun stapler staple "$APP_BUNDLE"

echo "[4/4] Verifying..."
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

echo ""
echo "✓ Notarized + stapled: $APP_BUNDLE"
echo "  Ready for distribution via DMG / zip."
