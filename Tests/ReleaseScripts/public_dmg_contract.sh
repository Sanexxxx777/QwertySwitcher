#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIGNING_DOC="$PROJECT_DIR/docs/SIGNING.md"
DMG_SCRIPT="$PROJECT_DIR/Scripts/make-dmg.sh"
APP_BUILD_SCRIPT="$PROJECT_DIR/Scripts/build.sh"

DMG_NOTARIZE_SCRIPT="$PROJECT_DIR/Scripts/notarize.sh"
developer_id_line=$(grep -n './Scripts/make-dmg.sh developerid' "$SIGNING_DOC" | head -1 | cut -d: -f1)
notarize_line=$(grep -n './Scripts/notarize.sh dmg' "$SIGNING_DOC" | head -1 | cut -d: -f1)
identity_check_line=$(grep -n 'security find-identity -v -p codesigning' "$DMG_SCRIPT" | head -1 | cut -d: -f1)
compile_line=$(grep -n 'swift build.*arm64-apple-macosx13.0' "$DMG_SCRIPT" | head -1 | cut -d: -f1)
bundle_move_line=$(grep -n 'mv "$APP_BUNDLE"' "$DMG_SCRIPT" | head -1 | cut -d: -f1)
dmg_create_line=$(grep -n 'hdiutil create' "$DMG_SCRIPT" | head -1 | cut -d: -f1)
dmg_sign_line=$(grep -n 'codesign.*DMG_OUT' "$DMG_SCRIPT" | head -1 | cut -d: -f1 || true)

if [ -z "$developer_id_line" ] || [ -z "$notarize_line" ]; then
    echo "FAIL: public Developer ID workflow is incomplete"
    exit 1
fi

if [ "$developer_id_line" -ge "$notarize_line" ]; then
    echo "FAIL: final DMG must be created before it is submitted for notarization"
    exit 1
fi

if [ -z "$identity_check_line" ] || [ -z "$compile_line" ] || [ -z "$bundle_move_line" ]; then
    echo "FAIL: Developer ID prerequisite or build steps are missing"
    exit 1
fi

if [ "$identity_check_line" -ge "$compile_line" ] || [ "$identity_check_line" -ge "$bundle_move_line" ]; then
    echo "FAIL: Developer ID identity must be checked before compiling or replacing the current app"
    exit 1
fi

if [ -z "$dmg_create_line" ] || [ -z "$dmg_sign_line" ]; then
    echo "FAIL: final Developer ID disk image is not signed"
    exit 1
fi

if [ "$dmg_sign_line" -le "$dmg_create_line" ]; then
    echo "FAIL: disk image must be created before its final Developer ID signature"
    exit 1
fi

grep -q 'developerid)' "$DMG_SCRIPT" || {
    echo "FAIL: DMG builder has no explicit Developer ID mode"
    exit 1
}
grep -q 'diskutil image create from' "$DMG_SCRIPT" || {
    echo "FAIL: DMG builder does not use the supported macOS disk image command"
    exit 1
}
grep -q -- '--timestamp' "$DMG_SCRIPT" || {
    echo "FAIL: Developer ID signing has no secure timestamp"
    exit 1
}
grep -q 'TIMESTAMP_ARGS=(--timestamp)' "$APP_BUILD_SCRIPT" || {
    echo "FAIL: standalone Developer ID app build has no secure timestamp"
    exit 1
}
grep -q '"${TIMESTAMP_ARGS\[@\]}"' "$APP_BUILD_SCRIPT" || {
    echo "FAIL: standalone Developer ID timestamp option is not passed to codesign"
    exit 1
}
grep -q 'codesign --verify.*DMG_PATH' "$DMG_NOTARIZE_SCRIPT" || {
    echo "FAIL: notarization does not verify the final DMG signature before submission"
    exit 1
}
grep -q 'notarytool submit.*SUBMISSION_PATH' "$DMG_NOTARIZE_SCRIPT" || {
    echo "FAIL: notarization does not submit the selected final artifact"
    exit 1
}
grep -q 'stapler staple.*STAPLE_PATH' "$DMG_NOTARIZE_SCRIPT" || {
    echo "FAIL: notarization ticket is not stapled to the selected final artifact"
    exit 1
}

echo "PASS: Developer ID DMG is built first, then that final artifact is notarized and stapled"
