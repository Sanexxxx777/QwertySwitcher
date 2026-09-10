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
echo "[1/8] Building universal .app and DMG..."
./Scripts/make-dmg.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PROJECT_DIR/Resources/Info.plist")
APP_BUNDLE="$PROJECT_DIR/build/Qwerty Switcher.app"
DMG_PATH="$PROJECT_DIR/build/QwertySwitcher-$VERSION.dmg"
ZIP_PATH="$PROJECT_DIR/build/QwertySwitcher-$VERSION.zip"

[ -d "$APP_BUNDLE" ] || { echo "✗ $APP_BUNDLE not found after make-dmg.sh"; exit 3; }
[ -f "$DMG_PATH" ]   || { echo "✗ $DMG_PATH not found after make-dmg.sh"; exit 3; }

# ── 2. Update-feed archive ──
echo "[2/8] Packaging update archive..."
rm -f "$ZIP_PATH"
(cd "$PROJECT_DIR/build" && ditto -c -k --keepParent "Qwerty Switcher.app" "$(basename "$ZIP_PATH")")

SIZE=$(stat -f %z "$ZIP_PATH")
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "  zip: $ZIP_PATH ($SIZE bytes, sha256 $SHA256)"

# ── 3. Manifest ──
echo "[3/8] Building manifest..."
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
echo "[4/8] Signing with $KEY_ID..."
[ -f "$KEY_PATH" ] || { echo "✗ private key not found: $KEY_PATH"; exit 4; }
APPCAST_PATH="$PROJECT_DIR/build/appcast.json"
swift "$PROJECT_DIR/Scripts/sign-update.swift" sign \
    --key "$KEY_PATH" --key-id "$KEY_ID" --manifest "$MANIFEST_PATH" --out "$APPCAST_PATH"

# ── 4.5. Verify against the key ACTUALLY EMBEDDED in the app (MAJOR fix,
#    security review: signing with the wrong key — e.g. k1/k2 swapped by
#    mistake — used to only be caught by a real client's badSignature much
#    later). The public key is extracted straight from UpdateKeyRing.swift
#    with grep, not duplicated as a separate literal here, so this can never
#    drift out of sync with what the app itself trusts. ──
echo "[4.5/8] Verifying appcast against UpdateKeyRing.swift's embedded $KEY_ID..."
KEYRING_SOURCE="$PROJECT_DIR/Sources/QwertySwitcher/Services/Updates/UpdateKeyRing.swift"
[ -f "$KEYRING_SOURCE" ] || { echo "✗ $KEYRING_SOURCE not found"; exit 5; }
EMBEDDED_PUBLIC_KEY=$(grep -o "\"$KEY_ID\": *\"[A-Za-z0-9+/=]*\"" "$KEYRING_SOURCE" \
    | head -1 | sed -E 's/.*"([A-Za-z0-9+\/=]+)"$/\1/')
[ -n "$EMBEDDED_PUBLIC_KEY" ] || { echo "✗ could not find a public key for $KEY_ID in UpdateKeyRing.swift"; exit 5; }
swift "$PROJECT_DIR/Scripts/sign-update.swift" verify --public "$EMBEDDED_PUBLIC_KEY" --appcast "$APPCAST_PATH" \
    || { echo "✗ appcast does not verify against the $KEY_ID key embedded in the app — aborting release"; exit 5; }

# ── 5. Secret scan (bundle, source tree, and the downloads folder before publish) ──
echo "[5/8] Secret scan..."
bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$APP_BUNDLE"
bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$PROJECT_DIR/Sources"
if [ -d "$DOWNLOADS_DIR" ]; then
    bash "$PROJECT_DIR/Scripts/release-secret-scan.sh" "$DOWNLOADS_DIR"
fi

# ── 6. Publish into the store checkout ──
echo "[6/8] Copying to $DOWNLOADS_DIR ..."
if [ -d "$STORE_DIR" ]; then
    mkdir -p "$FEED_DIR"
    # Keep the version being published AND the immediately-previous one (a
    # rollback from the store page must stay possible) — only delete
    # anything OLDER than that. `sort -rn` by mtime, `tail -n +2` skips the
    # most-recently-modified OTHER version (kept), deleting the rest.
    for ext in dmg zip; do
        find "$DOWNLOADS_DIR" -maxdepth 1 -name "QwertySwitcher-*.${ext}" ! -name "QwertySwitcher-$VERSION.${ext}" \
            -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | tail -n +2 | cut -d' ' -f2- \
            | while IFS= read -r old; do rm -f "$old"; done
    done
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
echo "[8/8] Done. Nothing was pushed or released — run these yourself:"
echo ""
echo "  cd \"$STORE_DIR\" && git add -A && git commit -m \"Qwerty Switcher $VERSION\" && git push"
echo "  cd \"$PROJECT_DIR\" && git add -A && git commit -m \"Release $VERSION (build $BUILD)\" && git push"
echo "  gh release create v$VERSION \"$DMG_PATH\" \"$ZIP_PATH\" \"$APPCAST_PATH\" --title \"Qwerty Switcher $VERSION\" --notes \"$NOTES\""
echo ""
echo "✓ appcast: $APPCAST_PATH"
echo "✓ dmg:     $DMG_PATH"
echo "✓ zip:     $ZIP_PATH"
