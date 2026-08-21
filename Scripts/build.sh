#!/bin/bash
# Qwerty Switcher build script — supports three signing modes.
#
#   dev       (default) — persistent self-signed identity. TCC permissions
#                         survive rebuilds. No Apple Developer Program needed.
#   developerid        — Developer ID Application cert. Needed for public
#                         distribution outside the App Store (DMG + notarize).
#   appstore           — Apple Distribution cert. Needed when submitting.
#                         Requires sandbox entitlements (separate plist).
#
# Usage:
#   ./Scripts/build.sh               # dev mode
#   ./Scripts/build.sh developerid
#   ./Scripts/build.sh appstore
set -euo pipefail

MODE="${1:-dev}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
PRODUCT_NAME="Qwerty Switcher"
BINARY_NAME="QwertySwitcher"
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"

SWIFT_SDK_ARGS=()
DEVELOPER_PATH=$(xcode-select -p 2>/dev/null || true)
COMPATIBLE_CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ "$DEVELOPER_PATH" != *"Xcode.app/Contents/Developer"* ]] && [ -d "$COMPATIBLE_CLT_SDK" ]; then
    SWIFT_SDK_ARGS=(--sdk "$COMPATIBLE_CLT_SDK")
    echo "Using compatible CLT SDK: $COMPATIBLE_CLT_SDK"
fi

ENTITLEMENTS="$PROJECT_DIR/Resources/QwertySwitcher.entitlements"
case "$MODE" in
    dev)          SIGN_IDENTITY="SashaSwitcher Developer" ;;
    developerid)  SIGN_IDENTITY="${DEVELOPER_ID_APP:-Developer ID Application}" ;;
    appstore)     SIGN_IDENTITY="${APPLE_DISTRIBUTION:-Apple Distribution}"
                  # App Store build uses a dedicated entitlements file
                  ENTITLEMENTS="$PROJECT_DIR/Resources/QwertySwitcher.appstore.entitlements" ;;
    *)            echo "Unknown mode: $MODE. Use dev | developerid | appstore"; exit 2 ;;
esac

AVAILABLE=""
TIMESTAMP_ARGS=()
if [ "$MODE" = "developerid" ]; then
    TIMESTAMP_ARGS=(--timestamp)
fi
if [ "$MODE" = "appstore" ]; then
    if [ -z "${APP_STORE_PROVISIONING_PROFILE:-}" ] || [ ! -f "$APP_STORE_PROVISIONING_PROFILE" ]; then
        echo "✗ Set APP_STORE_PROVISIONING_PROFILE to the registered .provisionprofile."
        exit 4
    fi
fi
if [ "$MODE" != "dev" ]; then
    AVAILABLE=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 || true)
    if [ -z "$AVAILABLE" ]; then
        echo "✗ '$SIGN_IDENTITY' not found — install your Apple certificate first."
        echo "  For $MODE you need a paid Apple Developer Program account."
        exit 3
    fi
fi

echo "=== Building $PRODUCT_NAME (mode: $MODE) ==="

bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$PROJECT_DIR/Resources"

# ── 1. Compile Swift ──
echo "[1/4] Compiling Swift..."
cd "$PROJECT_DIR"
swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release 2>&1 | tail -5

# ── 2. Create .app bundle structure ──
echo "[2/4] Creating app bundle..."
if [ -e "$APP_BUNDLE" ]; then
    # Keep exactly ONE previous copy, inside build/previous (build dir is
    # .noindex — Spotlight must never see stale bundles as separate apps).
    PREVIOUS_APP="$BUILD_DIR/previous/$PRODUCT_NAME.app"
    mkdir -p "$BUILD_DIR/previous"
    rm -rf "$PREVIOUS_APP"
    mv "$APP_BUNDLE" "$PREVIOUS_APP"
    echo "  previous build preserved at: $PREVIOUS_APP"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Dictionaries"

BINARY_PATH=$(swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c release --show-bin-path)/$BINARY_NAME
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"

if [ -d "$PROJECT_DIR/Resources/Dictionaries" ]; then
    cp "$PROJECT_DIR/Resources/Dictionaries/"*.txt "$APP_BUNDLE/Contents/Resources/Dictionaries/" 2>/dev/null || true
fi

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

if [ "$MODE" = "appstore" ]; then
    cp "$APP_STORE_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

# Bundled fonts (NFA design system)
if [ -d "$PROJECT_DIR/Resources/Fonts" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
    cp "$PROJECT_DIR/Resources/Fonts/"*.ttf "$APP_BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
fi

bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$APP_BUNDLE"


# ── 3. Code sign ──
echo "[3/4] Code signing ($MODE)..."

# For dev (self-signed) we don't use -v because macOS marks self-signed certs
# as CSSMERR_TP_NOT_TRUSTED even though codesign happily uses them. For Apple
# certs we stay strict (-v) so we don't accidentally sign with an expired cert.
if [ "$MODE" = "dev" ]; then
    AVAILABLE=$(security find-identity -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 || true)
fi
if [ -z "$AVAILABLE" ]; then
    case "$MODE" in
        dev)
            echo "  ⚠ '$SIGN_IDENTITY' not found in Keychain."
            echo "    Run once:  ./Scripts/setup-signing.sh"
            echo "    Falling back to ad-hoc (TCC permissions will reset on each rebuild)."
            codesign --force --deep --sign - "$APP_BUNDLE"
            ;;
        developerid|appstore)
            echo "  ✗ '$SIGN_IDENTITY' not found — install your Apple certificate first."
            echo "    For $MODE you need a paid Apple Developer Program account."
            exit 3 ;;
    esac
else
    echo "  using: $AVAILABLE"
    # Hardened Runtime (required for notarization + App Store)
    # Use --entitlements so TCC and Gatekeeper can see our declared capabilities.
    codesign --force --deep --options runtime \
        ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
fi

# Strip quarantine so Gatekeeper doesn't block self-built binaries
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# ── 4. Verify ──
echo "[4/4] Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo ""
echo "✓ App bundle: $APP_BUNDLE"
echo "  size:        $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "  identifier:  $(codesign -dv "$APP_BUNDLE" 2>&1 | grep 'Identifier=' | cut -d= -f2 || echo '?')"
echo "  team:        $(codesign -dv "$APP_BUNDLE" 2>&1 | grep 'TeamIdentifier=' | cut -d= -f2 || echo 'adhoc')"

case "$MODE" in
    dev)
        echo ""
        echo "Run: open '$APP_BUNDLE'"
        ;;
    developerid)
        echo ""
        echo "Next: notarize with ./Scripts/notarize.sh"
        ;;
    appstore)
        echo ""
        echo "Next: package with ./Scripts/appstore-package.sh, then upload via Transporter."
        ;;
esac
