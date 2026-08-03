#!/bin/bash
# Package an already App Store-signed Qwerty Switch.app for Transporter/App Store Connect.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/Qwerty Switch.app"
PKG_PATH="$PROJECT_DIR/build/QwertySwitch-AppStore.pkg"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-Mac Installer Distribution}"
EXPECTED_BUNDLE_ID="tech.sasha.qwertyswitch"
PROFILE_PATH="$APP_BUNDLE/Contents/embedded.provisionprofile"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "✗ Build first: APP_STORE_PROVISIONING_PROFILE=/path/profile ./Scripts/build.sh appstore"
    exit 1
fi

if [ ! -f "$PROFILE_PATH" ]; then
    echo "✗ App Store provisioning profile is not embedded in the app."
    exit 3
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist")
if [ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "✗ Unexpected bundle ID: $ACTUAL_BUNDLE_ID"
    exit 4
fi

SIGNATURE_INFO=$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)
if ! printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Authority=Apple Distribution'; then
    echo "✗ App is not signed with an Apple Distribution certificate."
    exit 5
fi

VALIDATION_DIR=$(mktemp -d /private/tmp/qwerty-switch-appstore.XXXXXX)
APP_ENTITLEMENTS="$VALIDATION_DIR/app-entitlements.plist"
PROFILE_PLIST="$VALIDATION_DIR/profile.plist"
cleanup() {
    case "$VALIDATION_DIR" in
        /private/tmp/qwerty-switch-appstore.*) rm -r "$VALIDATION_DIR" ;;
        *) echo "Refusing to remove unexpected validation path: $VALIDATION_DIR" ;;
    esac
}
trap cleanup EXIT

codesign --display --entitlements - --xml "$APP_BUNDLE" > "$APP_ENTITLEMENTS"
SANDBOX_ENABLED=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$APP_ENTITLEMENTS" 2>/dev/null || true)
if [ "$SANDBOX_ENABLED" != "true" ]; then
    echo "✗ App Store app is missing com.apple.security.app-sandbox=true."
    exit 6
fi

security cms -D -i "$PROFILE_PATH" -o "$PROFILE_PLIST"
PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST" 2>/dev/null || true)
case "$PROFILE_APP_ID" in
    *."$EXPECTED_BUNDLE_ID") ;;
    *)
        echo "✗ Embedded provisioning profile does not match $EXPECTED_BUNDLE_ID."
        exit 7
        ;;
esac

AVAILABLE=$(security find-identity -v 2>/dev/null | grep -F "$INSTALLER_IDENTITY" | head -1 || true)
if [ -z "$AVAILABLE" ]; then
    echo "✗ Installer identity '$INSTALLER_IDENTITY' not found in Keychain."
    exit 2
fi

rm -f "$PKG_PATH"
productbuild --component "$APP_BUNDLE" /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$PKG_PATH"
pkgutil --check-signature "$PKG_PATH"
echo "✓ App Store package: $PKG_PATH"
