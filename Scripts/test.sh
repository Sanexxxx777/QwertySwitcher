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
    "$BIN_DIR/QwertySwitcher" --test
    exit $?
fi

echo "Full Xcode/SwiftUIMacros not found — running deterministic core suite."
mkdir -p .build/core-tests/module-cache

swiftc \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework Carbon \
    -framework IOKit \
    -module-cache-path .build/core-tests/module-cache \
    -o .build/core-tests/QwertySwitcherCoreTests \
    Tests/CoreHarness/StatusIndicatorStub.swift \
    Tests/CoreHarness/main.swift \
    Sources/QwertySwitcher/AppIdentity.swift \
    Sources/QwertySwitcher/Core/AutoLearnTracker.swift \
    Sources/QwertySwitcher/Core/DebugLog.swift \
    Sources/QwertySwitcher/Core/EventTapHealth.swift \
    Sources/QwertySwitcher/Core/HotkeyManager.swift \
    Sources/QwertySwitcher/Core/InputBuffer.swift \
    Sources/QwertySwitcher/Core/InputSourceManager.swift \
    Sources/QwertySwitcher/Core/InstantCorrectionAnalyzer.swift \
    Sources/QwertySwitcher/Core/InstantCorrectionGate.swift \
    Sources/QwertySwitcher/Core/KeyboardMonitor.swift \
    Sources/QwertySwitcher/Core/LanguageDetector.swift \
    Sources/QwertySwitcher/Core/NGramAnalyzer.swift \
    Sources/QwertySwitcher/Core/PendingUserEventQueue.swift \
    Sources/QwertySwitcher/Core/SecureInputDetector.swift \
    Sources/QwertySwitcher/Core/ShiftStateTracker.swift \
    Sources/QwertySwitcher/Core/ShiftTapResolver.swift \
    Sources/QwertySwitcher/Core/SyntheticEventMarker.swift \
    Sources/QwertySwitcher/Core/TextReplacer.swift \
    Sources/QwertySwitcher/Core/UndoManager.swift \
    Sources/QwertySwitcher/Core/WordFrequency.swift \
    Sources/QwertySwitcher/Dictionary/BloomFilter.swift \
    Sources/QwertySwitcher/Dictionary/WordDictionary.swift \
    Sources/QwertySwitcher/Models/Language.swift \
    Sources/QwertySwitcher/Services/AutoStartService.swift \
    Sources/QwertySwitcher/Services/DeviceIdentity.swift \
    Sources/QwertySwitcher/Services/ExceptionsService.swift \
    Sources/QwertySwitcher/Services/LicenseService.swift \
    Sources/QwertySwitcher/Services/PerAppLayoutService.swift \
    Sources/QwertySwitcher/Services/PermissionsService.swift \
    Sources/QwertySwitcher/Services/PreferencesService.swift \
    Sources/QwertySwitcher/Services/PrivacyService.swift \
    Sources/QwertySwitcher/Services/SoundService.swift \
    Sources/QwertySwitcher/Services/StatisticsService.swift \
    Sources/QwertySwitcher/Services/StorageMigrationService.swift \
    Sources/QwertySwitcher/Services/YoficatorService.swift \
    Sources/QwertySwitcher/Tests/TestRunner.swift

.build/core-tests/QwertySwitcherCoreTests
