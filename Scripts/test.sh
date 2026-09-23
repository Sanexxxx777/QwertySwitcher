#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Test isolation (incident 05.08.2026 — see CLAUDE.md): the --test binary
# below is ALREADY safe by default (DebugLog and InputSourceManager both key
# off the --test launch argument itself), but QSW_LOG_DIR gives this run's
# log a stable, inspectable path instead of a throwaway temp one when a test
# fails and needs a look. Exported once so it's inherited by whichever of the
# two test-binary invocations below actually runs.
QSW_TEST_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qsw-test-logs.XXXXXX")"
trap 'rm -rf "$QSW_TEST_LOG_DIR"' EXIT
export QSW_LOG_DIR="$QSW_TEST_LOG_DIR"

DEVELOPER_PATH=$(xcode-select -p 2>/dev/null || true)
COMPATIBLE_CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
SWIFT_SDK_ARGS=()
CAN_BUILD_FULL_APP=false

if [[ "$DEVELOPER_PATH" == *"Xcode.app/Contents/Developer"* ]]; then
    CAN_BUILD_FULL_APP=true
elif [ -d "$COMPATIBLE_CLT_SDK" ]; then
    SWIFT_SDK_ARGS=(--sdk "$COMPATIBLE_CLT_SDK")
    CAN_BUILD_FULL_APP=true
    echo "Using compatible CLT SDK: $COMPATIBLE_CLT_SDK"
fi

# Shell-level contracts (release/install pipelines). They exercise real
# scripts, so they live outside the Swift suite — but they must gate the same
# exit code, otherwise nothing enforces them.
run_release_contracts() {
    local status=0
    echo ""
    echo "=== Release script contracts ==="
    for contract in "$PROJECT_DIR"/Tests/ReleaseScripts/*.sh; do
        [ -f "$contract" ] || continue
        if bash "$contract"; then
            :
        else
            echo "  ✗ $(basename "$contract")"
            status=1
        fi
    done
    return $status
}

if [ "$CAN_BUILD_FULL_APP" = true ]; then
    swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug
    BIN_DIR=$(swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug --show-bin-path)
    SWIFT_STATUS=0
    "$BIN_DIR/QwertySwitcher" --test || SWIFT_STATUS=$?
    CONTRACT_STATUS=0
    run_release_contracts || CONTRACT_STATUS=$?
    [ "$SWIFT_STATUS" -eq 0 ] && [ "$CONTRACT_STATUS" -eq 0 ] || exit 1
    exit 0
fi

echo "Neither Xcode nor the Command Line Tools SDK at $COMPATIBLE_CLT_SDK was found." >&2
echo "Install Xcode (or point xcode-select at it) and re-run ./Scripts/test.sh." >&2
exit 1
