#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

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

if [ "$CAN_BUILD_FULL_APP" = true ]; then
    swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug
    BIN_DIR=$(swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug --show-bin-path)
    "$BIN_DIR/SashaSwitcher" --test
    exit $?
fi

echo "Full Xcode/SwiftUIMacros not found — running deterministic core suite."
mkdir -p .build/core-tests/module-cache

swiftc \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework Carbon \
    -module-cache-path .build/core-tests/module-cache \
    -o .build/core-tests/QwertySwitchCoreTests \
    Tests/CoreHarness/StatusIndicatorStub.swift \
    Tests/CoreHarness/main.swift \
    Sources/SashaSwitcher/AppIdentity.swift \
    Sources/SashaSwitcher/Core/AutoLearnTracker.swift \
    Sources/SashaSwitcher/Core/DebugLog.swift \
    Sources/SashaSwitcher/Core/EventTapHealth.swift \
    Sources/SashaSwitcher/Core/HotkeyManager.swift \
    Sources/SashaSwitcher/Core/InputBuffer.swift \
    Sources/SashaSwitcher/Core/InputSourceManager.swift \
    Sources/SashaSwitcher/Core/KeyboardMonitor.swift \
    Sources/SashaSwitcher/Core/LanguageDetector.swift \
    Sources/SashaSwitcher/Core/NGramAnalyzer.swift \
    Sources/SashaSwitcher/Core/SecureInputDetector.swift \
    Sources/SashaSwitcher/Core/ShiftStateTracker.swift \
    Sources/SashaSwitcher/Core/ShiftTapResolver.swift \
    Sources/SashaSwitcher/Core/SyntheticEventMarker.swift \
    Sources/SashaSwitcher/Core/TextReplacer.swift \
    Sources/SashaSwitcher/Core/UndoManager.swift \
    Sources/SashaSwitcher/Core/WordFrequency.swift \
    Sources/SashaSwitcher/Dictionary/BloomFilter.swift \
    Sources/SashaSwitcher/Dictionary/WordDictionary.swift \
    Sources/SashaSwitcher/Models/Language.swift \
    Sources/SashaSwitcher/Services/AutoStartService.swift \
    Sources/SashaSwitcher/Services/ExceptionsService.swift \
    Sources/SashaSwitcher/Services/PerAppLayoutService.swift \
    Sources/SashaSwitcher/Services/PermissionsService.swift \
    Sources/SashaSwitcher/Services/PreferencesService.swift \
    Sources/SashaSwitcher/Services/PrivacyService.swift \
    Sources/SashaSwitcher/Services/SoundService.swift \
    Sources/SashaSwitcher/Services/StatisticsService.swift \
    Sources/SashaSwitcher/Services/StorageMigrationService.swift \
    Sources/SashaSwitcher/Services/YoficatorService.swift \
    Sources/SashaSwitcher/Tests/TestRunner.swift

.build/core-tests/QwertySwitchCoreTests
