#!/bin/bash
# Notarize a Developer ID-signed app or the final DMG and staple the ticket.
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
#   ./Scripts/build.sh developerid && ./Scripts/notarize.sh app
#   ./Scripts/make-dmg.sh developerid && ./Scripts/notarize.sh dmg

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/Qwerty Switch.app"
ZIP_PATH="$PROJECT_DIR/build/QwertySwitch.zip"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-notarize-sasha}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist")
DMG_PATH="$PROJECT_DIR/build/QwertySwitch-$VERSION.dmg"
TARGET="${1:-app}"

case "$TARGET" in
    app)
        if [ ! -d "$APP_BUNDLE" ]; then
            echo "✗ Build .app first: ./Scripts/build.sh developerid"
            exit 1
        fi
        codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
        SIGNATURE_INFO=$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)
        if ! printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Authority=Developer ID Application'; then
            echo "✗ App is not signed with a Developer ID Application certificate."
            exit 3
        fi
        echo "[1/4] Zipping app for submission..."
        rm -f "$ZIP_PATH"
        /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
        SUBMISSION_PATH="$ZIP_PATH"
        STAPLE_PATH="$APP_BUNDLE"
        ;;
    dmg)
        if [ ! -f "$DMG_PATH" ]; then
            echo "✗ Build Developer ID DMG first: ./Scripts/make-dmg.sh developerid"
            exit 1
        fi
        echo "[1/4] Verifying DMG before submission..."
        hdiutil verify "$DMG_PATH"
        codesign --verify --verbose=2 "$DMG_PATH"
        SIGNATURE_INFO=$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)
        if ! printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Authority=Developer ID Application'; then
            echo "✗ DMG is not signed with a Developer ID Application certificate."
            exit 3
        fi
        SUBMISSION_PATH="$DMG_PATH"
        STAPLE_PATH="$DMG_PATH"
        ;;
    *)
        echo "Unknown target: $TARGET. Use app | dmg"
        exit 2
        ;;
esac

echo "[2/4] Submitting to Apple notary service (may take 2–10 min)..."
xcrun notarytool submit "$SUBMISSION_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "[3/4] Stapling notarization ticket..."
xcrun stapler staple "$STAPLE_PATH"

echo "[4/4] Verifying..."
xcrun stapler validate "$STAPLE_PATH"
if [ "$TARGET" = "dmg" ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$STAPLE_PATH"
else
    spctl --assess --type execute --verbose=2 "$STAPLE_PATH"
fi

echo ""
echo "✓ Notarized + stapled: $STAPLE_PATH"
echo "  Ready for distribution."
