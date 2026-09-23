#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit

/// Lightweight test runner — no XCTest required.
/// Invoked via `swift run QwertySwitcher --test` or `./Scripts/test.sh`.
enum TestRunner {
    private static var failed = 0
    private static var passed = 0
    private static var skipped = 0

    /// macOS 27.0 beta can deadlock in SkyLight while constructing a
    /// synthetic keyboard CGEvent after TIS layout activity. Keep every pure
    /// test running and skip only fixtures that require a real CGEvent.
    static var syntheticKeyboardEventsAreSafe: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    static func run() -> Int {
        if CommandLine.arguments.contains("--test-release-safety") {
            DebugLogTests.run()
            UpdatesTests.run()
            print("Release safety: \(passed) passed, \(failed) failed, \(skipped) skipped")
            return failed == 0 ? 0 : 1
        }
        if CommandLine.arguments.contains("--test-hotkeys") {
            ShiftStateTests.run()
            ShiftTapResolverTests.run()
            ShiftTapModifierDisqualifierTests.run()
            ComboWindowGuardTests.run()
            print("Hotkeys: \(passed) passed, \(failed) failed, \(skipped) skipped")
            return failed == 0 ? 0 : 1
        }
        print("=== Qwerty Switcher test suite ===")
        // See InputSourceManager's `layoutSwitchingIsSimulated` doc — real
        // layout switching during a --test run is an explicit, rare opt-in
        // (QSW_ALLOW_REAL_LAYOUT_SWITCH=1) and must never be silent: it
        // switches the Mac's actual active keyboard layout while this runs.
        if InputSourceManager.isTestBinaryWithRealLayoutSwitchEnabled {
            print("⚠️⚠️⚠️  QSW_ALLOW_REAL_LAYOUT_SWITCH=1 — this run switches your Mac's REAL keyboard layout. Do not type until it finishes.  ⚠️⚠️⚠️")
        }
        BloomFilterTests.run()
        YoficatorTests.run()
        NGramTests.run()
        InputBufferTests.run()
        SecureInputCacheTests.run()
        EditingContextPolicyTests.run()
        ReplacementCancellationTests.run()
        SyntheticEventTests.run()
        ShiftStateTests.run()
        ShiftTapResolverTests.run()
        ShiftTapModifierDisqualifierTests.run()
        AutoLearnTrackerTests.run()
        ReplacementTransactionTests.run()
        LanguageSkipTests.run()
        InputSourceLanguageTests.run()
        PrivacyTests.run()
        ExceptionsTests.run()
        InstantCorrectionGateTests.run()
        PreferencesServiceTests.run()
        TimedPauseTests.run()
        SettingsBackupTests.run()
        SnippetTests.run()
        SmartCaseTests.run()
        InstantCorrectionUndoTests.run()
        InstantCorrectionAnalyzerTests.run()
        InstantCorrectionCorpusTests.run()
        InstantCorrectionJunkGateTests.run()
        DebugLogTests.run()
        PendingUserEventQueueTests.run()
        EventRouteTests.run()
        BufferVsScreenModelTests.run()
        InstantCorrectionGateSelfSwitchTests.run()
        InputSourceSelfSwitchTests.run()
        SlashModelRegressionTests.run()
        LeadingSymbolRunGuardTests.run()
        SoundServiceTests.run()
        CaretWordExtractorTests.run()
        LayoutTextConverterTests.run()
        DominantScriptLanguageTests.run()
        LogRetentionTests.run()
        MarzheDoubleShiftRegressionTests.run()
        TwoLetterWordScoringTests.run()
        NativeContextIncumbentAndOneLetterTests.run()
        OwnerAbbreviationRegressionTests.run()
        ConflictPairDisambiguationTests.run()
        JunkOverrideDetectionTests.run()
        JunkMeterTests.run()
        OnboardingStateTests.run()
        KeyboardMonitorIntegrationTests.run()
        CorrectionAvalancheGuardTests.run()
        QueueReplacementActiveTests.run()
        AvalancheGuardWiringTests.run()
        HotPathStructuralGuardTests.run()
        ReplacementAtomicityGuardTests.run()
        DoubleShiftSelectionGuardTests.run()
        ComboWindowGuardTests.run()
        RunResyncStructuralGuardTests.run()
        RunResyncPredicateTests.run()
        OverlayMismatchGuardTests.run()
        VerifiedEraseGuardTests.run()
        PasteNoFormatGuardTests.run()
        StatusInkContrastTests.run()
        SecureInputAXTierTests.run()
        CallbackDurationThresholdTests.run()
        TapTimeoutCounterTests.run()
        SwitchBlockReasonTests.run()
        SoundServiceToggleCueTests.run()
        DockIconPolicyTests.run()
        LearnedWordsStoreTests.run()
        PersonalFrequencyStoreTests.run()
        CorrectionFeedbackTrackerTests.run()
        LearningNormalizationTests.run()
        InstantLearningBypassTests.run()
        BoundaryLearningBypassTests.run()
        LearningKeyboardMonitorIntegrationTests.run()
        LearningReplayChainTests.run()
        GameModeReleaseGuardTests.run()
        GameAppProbeTests.run()
        GameModeStateTests.run()
        HeldKeysGameModeGateTests.run()
        SanityCapBoundaryGuardTests.run()
        BackspaceResetsInstantGateTests.run()
        DoubleShiftInapplicableLogTests.run()
        ProviderSingleReadGuardTests.run()
        GameModeSourceGuardTests.run()
        DetectorExactnessTests.run()
        AuthorLinksViewTests.run()
        ResyncExtendGuardTests.run()
        StorageMigrationV2Tests.run()
        IslandTests.run()
        ShortTokenTests.run()
        BigramTablesTests.run()
        UpdatesTests.run()
        print("---")
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 ? 0 : 1
    }

    static func assertTrue(_ cond: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if cond() {
            passed += 1
            print("  ✓ \(message)")
        } else {
            failed += 1
            print("  ✗ \(message)  — \(file):\(line)")
        }
    }

    static func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if a == b {
            passed += 1
            print("  ✓ \(message)")
        } else {
            failed += 1
            print("  ✗ \(message) — expected \(b), got \(a)  — \(file):\(line)")
        }
    }

    static func assertNil<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if value == nil {
            passed += 1
            print("  ✓ \(message)")
        } else {
            failed += 1
            print("  ✗ \(message) — expected nil, got \(String(describing: value))  — \(file):\(line)")
        }
    }

    static func section(_ name: String) {
        print("\n[\(name)]")
    }

    static func skip(_ message: String) {
        skipped += 1
        print("  ↷ SKIP: \(message)")
    }
}
#endif
