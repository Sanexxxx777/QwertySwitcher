#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_SCRIPT="$PROJECT_DIR/Scripts/build.sh"
PACKAGE_SCRIPT="$PROJECT_DIR/Scripts/appstore-package.sh"

profile_check_line=$(grep -n 'APP_STORE_PROVISIONING_PROFILE' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)
compile_line=$(grep -n 'swift build.*-c release' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)
bundle_move_line=$(grep -n 'mv "$APP_BUNDLE"' "$BUILD_SCRIPT" | head -1 | cut -d: -f1)

if [ -z "$profile_check_line" ] || [ -z "$compile_line" ] || [ -z "$bundle_move_line" ]; then
    echo "FAIL: App Store build prerequisites or build steps are missing"
    exit 1
fi

if [ "$profile_check_line" -ge "$compile_line" ] || [ "$profile_check_line" -ge "$bundle_move_line" ]; then
    echo "FAIL: provisioning profile must be checked before compiling or replacing the current app"
    exit 1
fi

grep -q 'embedded.provisionprofile' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not require the embedded provisioning profile"
    exit 1
}
grep -q 'codesign --verify --deep --strict' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not verify the app signature"
    exit 1
}
grep -q 'com.apple.security.app-sandbox' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not verify the sandbox entitlement"
    exit 1
}
grep -q 'tech.sasha.qwertyswitch' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not verify the expected bundle identifier"
    exit 1
}
grep -q 'security cms -D' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not decode the embedded provisioning profile"
    exit 1
}
grep -q 'productbuild --component' "$PACKAGE_SCRIPT" || {
    echo "FAIL: package script does not create the App Store package"
    exit 1
}

echo "PASS: App Store app is preflighted and validated before packaging"
