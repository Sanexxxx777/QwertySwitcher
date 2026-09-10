#!/bin/bash
# Qwerty Switcher release packaging: universal DMG + signed update-feed zip +
# appcast.json, copied into the shulgin.is-a.dev store checkout. Never pushes
# or publishes anything itself — the git/gh commands for that are PRINTED at
# the end for the owner to run by hand.
#
# Usage:
#   ./Scripts/release.sh                  # sign with k1 (default)
#   ./Scripts/release.sh k2                # sign with k2
#   ./Scripts/release.sh k1 "release notes text"
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE_DIR="$HOME/Projects/web/store"
DOWNLOADS_DIR="$STORE_DIR/downloads"
FEED_DIR="$DOWNLOADS_DIR/qwertyswitcher"

KEY_ID="${1:-k1}"
case "$KEY_ID" in
    k1|k2) ;;
    *) echo "Usage: $0 [k1|k2] [release notes]"; exit 2 ;;
esac
NOTES_ARG="${2:-}"
KEY_PATH="$HOME/.claude/secrets/qsw_update_ed25519_${KEY_ID}.key"

echo "=== Qwerty Switcher release (signing key: $KEY_ID) ==="

# ── 0. Git cleanliness — warn only, packaging is not blocked on it ──
cd "$PROJECT_DIR"
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    echo "⚠ working tree is not clean — packaging from it anyway (warning, not a block)"
fi

# ── 1. Universal build + DMG (make-dmg.sh already signs + secret-scans) ──
echo "[1/7] Building universal .app and DMG..."
./Scripts/make-dmg.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PROJECT_DIR/Resources/Info.plist")
APP_BUNDLE="$PROJECT_DIR/build/Qwerty Switcher.app"
DMG_PATH="$PROJECT_DIR/build/QwertySwitcher-$VERSION.dmg"
ZIP_PATH="$PROJECT_DIR/build/QwertySwitcher-$VERSION.zip"

[ -d "$APP_BUNDLE" ] || { echo "✗ $APP_BUNDLE not found after make-dmg.sh"; exit 3; }
[ -f "$DMG_PATH" ]   || { echo "✗ $DMG_PATH not found after make-dmg.sh"; exit 3; }

# ── 2. Update-feed archive ──
echo "[2/7] Packaging update archive..."
rm -f "$ZIP_PATH"
(cd "$PROJECT_DIR/build" && ditto -c -k --keepParent "Qwerty Switcher.app" "$(basename "$ZIP_PATH")")

SIZE=$(stat -f %z "$ZIP_PATH")
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "  zip: $ZIP_PATH ($SIZE bytes, sha256 $SHA256)"

# ── 3. Manifest ──
echo "[3/7] Building manifest..."
PUBLISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
VALID_UNTIL=$(date -u -v+180d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "+180 days" +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$NOTES_ARG" ]; then
    NOTES="$NOTES_ARG"
elif [ -f "$PROJECT_DIR/RELEASE_NOTES.md" ]; then
    NOTES="$(cat "$PROJECT_DIR/RELEASE_NOTES.md")"
else
    NOTES="Qwerty Switcher $VERSION"
fi

ARCHIVE_URL="https://shulgin.is-a.dev/store/downloads/qwertyswitcher/QwertySwitcher-$VERSION.zip"
MANIFEST_PATH="$PROJECT_DIR/build/manifest-$VERSION.json"

python3 - "$MANIFEST_PATH" "$VERSION" "$BUILD" "$ARCHIVE_URL" "$SIZE" "$SHA256" "$PUBLISHED_AT" "$VALID_UNTIL" "$NOTES" <<'PY'
import json, sys
path, version, build, archive_url, size, sha256, published_at, valid_until, notes = sys.argv[1:10]
manifest = {
    "version": version,
    "build": int(build),
    "minSystemVersion": "13.0",
    "archiveURL": archive_url,
    "size": int(size),
    "sha256": sha256,
    "publishedAt": published_at,
    "validUntil": valid_until,
    "notes": notes,
}
with open(path, "w") as f:
    json.dump(manifest, f, sort_keys=True, separators=(",", ":"))
PY

echo "  manifest: $MANIFEST_PATH"

# ── 4. Sign ──
echo "[4/7] Signing with $KEY_ID..."
[ -f "$KEY_PATH" ] || { echo "✗ private key not found: $KEY_PATH"; exit 4; }
APPCAST_PATH="$PROJECT_DIR/build/appcast.json"
swift "$PROJECT_DIR/Scripts/sign-update.swift" sign \
    --key "$KEY_PATH" --key-id "$KEY_ID" --manifest "$MANIFEST_PATH" --out "$APPCAST_PATH"

# ── 5. Secret scan (bundle again, and the downloads folder before publish) ──
echo "[5/7] Secret scan..."
bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$APP_BUNDLE"
if [ -d "$DOWNLOADS_DIR" ]; then
    bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$DOWNLOADS_DIR"
fi

# ── 6. Publish into the store checkout ──
echo "[6/7] Copying to $DOWNLOADS_DIR ..."
if [ -d "$STORE_DIR" ]; then
    mkdir -p "$FEED_DIR"
    find "$DOWNLOADS_DIR" -maxdepth 1 -name 'QwertySwitcher-*.dmg' ! -name "QwertySwitcher-$VERSION.dmg" -exec rm -f {} \;
    find "$DOWNLOADS_DIR" -maxdepth 1 -name 'QwertySwitcher-*.zip' ! -name "QwertySwitcher-$VERSION.zip" -exec rm -f {} \;
    cp "$DMG_PATH" "$DOWNLOADS_DIR/"
    cp "$ZIP_PATH" "$DOWNLOADS_DIR/"
    cp "$APPCAST_PATH" "$FEED_DIR/appcast.json"

    for page in "$STORE_DIR/index.html" "$STORE_DIR/en/index.html"; do
        [ -f "$page" ] || continue
        OLD_LINK=$(grep -o 'downloads/QwertySwitcher-[0-9][^"'"'"']*\.dmg' "$page" | head -1 || true)
        if [ -n "$OLD_LINK" ]; then
            sed -i '' "s|$OLD_LINK|downloads/QwertySwitcher-$VERSION.dmg|g" "$page"
            echo "  updated DMG link in $page"
        fi
    done
else
    echo "  note: $STORE_DIR not found — skipping publish step"
fi

# ── 7. Owner commands — PRINTED, never run from here ──
echo "[7/7] Done. Nothing was pushed or released — run these yourself:"
echo ""
echo "  cd \"$STORE_DIR\" && git add -A && git commit -m \"Qwerty Switcher $VERSION\" && git push"
echo "  cd \"$PROJECT_DIR\" && git add -A && git commit -m \"Release $VERSION (build $BUILD)\" && git push"
echo "  gh release create v$VERSION \"$DMG_PATH\" \"$ZIP_PATH\" \"$APPCAST_PATH\" --title \"Qwerty Switcher $VERSION\" --notes \"$NOTES\""
echo ""
echo "✓ appcast: $APPCAST_PATH"
echo "✓ dmg:     $DMG_PATH"
echo "✓ zip:     $ZIP_PATH"
