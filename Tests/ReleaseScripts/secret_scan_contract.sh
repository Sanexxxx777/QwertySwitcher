#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$PROJECT_DIR/Scripts/release-secret-scan.sh"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/qsw-secret-scan.XXXXXX")
trap 'rm -r "$TEMP_DIR"' EXIT

printf 'release_fixture=clean\n' > "$TEMP_DIR/clean.txt"
bash "$SCANNER" "$TEMP_DIR/clean.txt" >/dev/null

printf 'SPARKLE_PRIVATE_KEY=fixture-only\n' > "$TEMP_DIR/credential.txt"
if bash "$SCANNER" "$TEMP_DIR/credential.txt" >/dev/null 2>&1; then
    echo "FAIL: scanner accepted a credential assignment"
    exit 1
fi

mkdir "$TEMP_DIR/bundle"
printf 'placeholder=true\n' > "$TEMP_DIR/bundle/env.local.example"
if bash "$SCANNER" "$TEMP_DIR/bundle" >/dev/null 2>&1; then
    echo "FAIL: scanner accepted a credential-like resource filename"
    exit 1
fi

# MAJOR fix (security review, update-feed signing keys): a 44-char base64
# token (raw 32-byte Ed25519 key shape) on the same line as private/secret.
printf 'let privateKey = "wNhEr2ENSrWFn3RSbBtRXV7/slD/YL+JU5P77oSZO8o="\n' > "$TEMP_DIR/leaked_private_key.txt"
if bash "$SCANNER" "$TEMP_DIR/leaked_private_key.txt" >/dev/null 2>&1; then
    echo "FAIL: scanner accepted a private-key-shaped base64 token next to 'private'"
    exit 1
fi

# Negative fixture — this is the EXACT shape of our own legitimately embedded
# public keys (UpdateKeyRing.swift's `"k1": "<44 chars>"`); it must NOT be
# blocked, since it never mentions private/secret on the same line.
printf '"k1": "wNhEr2ENSrWFn3RSbBtRXV7/slD/YL+JU5P77oSZO8o=",\n' > "$TEMP_DIR/embedded_public_key.txt"
bash "$SCANNER" "$TEMP_DIR/embedded_public_key.txt" >/dev/null 2>&1 \
    || { echo "FAIL: scanner false-positived on a legitimately embedded PUBLIC key"; exit 1; }

grep -q 'release-secret-scan.sh.*PROJECT_DIR/Resources' "$PROJECT_DIR/Scripts/build.sh" || {
    echo "FAIL: app build does not scan source resources"
    exit 1
}
grep -q 'release-secret-scan.sh.*APP_BUNDLE' "$PROJECT_DIR/Scripts/build.sh" || {
    echo "FAIL: app build does not scan the assembled bundle"
    exit 1
}
grep -q 'release-secret-scan.sh.*DMG_STAGE' "$PROJECT_DIR/Scripts/make-dmg.sh" || {
    echo "FAIL: DMG build does not scan final staging"
    exit 1
}

PLIST="$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy"
if plutil -convert xml1 -o - "$PLIST" | grep -q 'NSPrivacyCollectedDataTypeDeviceID'; then
    echo "FAIL: privacy manifest declares a collected data type, but the app is offline (0.10.0+)"
    exit 1
fi

echo "PASS: release gates block credential files/material"
