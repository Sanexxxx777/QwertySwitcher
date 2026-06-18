#!/bin/bash
# SashaSwitcher build script — supports three signing modes.
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
set -e

MODE="${1:-dev}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="SashaSwitcher"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

ENTITLEMENTS="$PROJECT_DIR/Resources/SashaSwitcher.entitlements"
case "$MODE" in
    dev)          SIGN_IDENTITY="SashaSwitcher Developer" ;;
    developerid)  SIGN_IDENTITY="${DEVELOPER_ID_APP:-Developer ID Application}" ;;
    appstore)     SIGN_IDENTITY="${APPLE_DISTRIBUTION:-Apple Distribution}"
                  # App Store build uses a dedicated entitlements file
                  if [ -f "$PROJECT_DIR/Resources/SashaSwitcher.appstore.entitlements" ]; then
                      ENTITLEMENTS="$PROJECT_DIR/Resources/SashaSwitcher.appstore.entitlements"
                  fi ;;
    *)            echo "Unknown mode: $MODE. Use dev | developerid | appstore"; exit 2 ;;
esac

echo "=== Building $APP_NAME (mode: $MODE) ==="

# ── 1. Compile Swift ──
echo "[1/4] Compiling Swift..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -5

# ── 2. Create .app bundle structure ──
echo "[2/4] Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/Dictionaries"

BINARY_PATH=$(swift build -c release --show-bin-path)/$APP_NAME
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [ -d "$PROJECT_DIR/Resources/Dictionaries" ]; then
    cp "$PROJECT_DIR/Resources/Dictionaries/"*.txt "$APP_BUNDLE/Contents/Resources/Dictionaries/" 2>/dev/null || true
fi

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Bundled fonts (NFA design system)
if [ -d "$PROJECT_DIR/Resources/Fonts" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
    cp "$PROJECT_DIR/Resources/Fonts/"*.ttf "$APP_BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
fi

# ── 3. Code sign ──
echo "[3/4] Code signing ($MODE)..."

# For dev (self-signed) we don't use -v because macOS marks self-signed certs
# as CSSMERR_TP_NOT_TRUSTED even though codesign happily uses them. For Apple
# certs we stay strict (-v) so we don't accidentally sign with an expired cert.
if [ "$MODE" = "dev" ]; then
    AVAILABLE=$(security find-identity -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1 || true)
else
    AVAILABLE=$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1 || true)
fi
if [ -z "$AVAILABLE" ]; then
    case "$MODE" in
        dev)
            echo "  ⚠ '$SIGN_IDENTITY' not found in Keychain."
            echo "    Run once:  ./Scripts/setup-signing.sh"
            echo "    Falling back to ad-hoc (TCC permissions will reset on each rebuild)."
            codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "  ad-hoc sign failed"
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
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE" 2>&1 \
        | grep -v 'replacing existing signature' || true
fi

# Strip quarantine so Gatekeeper doesn't block self-built binaries
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# ── 4. Verify ──
echo "[4/4] Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -5 || true

echo ""
echo "✓ App bundle: $APP_BUNDLE"
echo "  size:        $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "  identifier:  $(codesign -dv "$APP_BUNDLE" 2>&1 | grep 'Identifier=' | cut -d= -f2 || echo '?')"
echo "  team:        $(codesign -dv "$APP_BUNDLE" 2>&1 | grep 'TeamIdentifier=' | cut -d= -f2 || echo 'adhoc')"

case "$MODE" in
    dev)
        echo ""
        echo "Run: open $APP_BUNDLE"
        ;;
    developerid)
        echo ""
        echo "Next: notarize with ./Scripts/notarize.sh"
        ;;
    appstore)
        echo ""
        echo "Next: package & upload with ./Scripts/appstore-upload.sh"
        ;;
esac
