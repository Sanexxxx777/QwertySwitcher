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
