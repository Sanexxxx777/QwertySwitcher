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

    static func run() -> Int {
        if CommandLine.arguments.contains("--test-release-safety") {
            DebugLogTests.run()
            UpdatesTests.run()
            sweepDefaultsSuites()
            print("Release safety: \(passed) passed, \(failed) failed, \(skipped) skipped")
            return failed == 0 ? 0 : 1
        }
        if CommandLine.arguments.contains("--test-hotkeys") {
            ShiftStateTests.run()
            ShiftTapResolverTests.run()
            ShiftTapModifierDisqualifierTests.run()
            ComboWindowGuardTests.run()
            sweepDefaultsSuites()
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
        ReplayBurstAndFailureTests.run()
        ChordCommaRepairTests.run()
        FirstBurstRetypeTests.run()
        AvalancheGuardWiringTests.run()
        HotPathStructuralGuardTests.run()
        ReplacementAtomicityGuardTests.run()
        DoubleShiftSelectionGuardTests.run()
        ComboWindowGuardTests.run()
        RunResyncStructuralGuardTests.run()
        RunResyncPredicateTests.run()
        OverlayMismatchGuardTests.run()
        VerifiedEraseGuardTests.run()
        SyntheticEventFlagsGuardTests.run()
        PasteNoFormatGuardTests.run()
        StatusInkContrastTests.run()
        SecureInputAXTierTests.run()
        CallbackDurationThresholdTests.run()
        TapAgeInterpretationTests.run()
        TapAgeProbeRouteGuardTests.run()
        TapTimeoutCounterTests.run()
        SwitchBlockReasonTests.run()
        SoundServiceToggleCueTests.run()
        SoundServiceQueueTests.run()
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
        PortParityTests.run()
        AuthorLinksViewTests.run()
        ResyncExtendGuardTests.run()
        StorageMigrationV2Tests.run()
        IslandTests.run()
        IslandRingIntegrationTests.run()
        ModelAndLearningFixesTests.run()
        ContextResetPolicyTests.run()
        ReleaseReviewFixesTests.run()
        TerminalAppsTests.run()
        ShortTokenTests.run()
        BigramTablesTests.run()
        UpdatesTests.run()
        SingleInstanceLockTests.run()
        DictionaryIndexTests.run()
        SourceContractHelperTests.run()
        sweepDefaultsSuites()
        print("---")
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 ? 0 : 1
    }

    /// Throwaway UserDefaults suites created by this run, deleted by
    /// `sweepDefaultsSuites()` before `run()` returns.
    private static var knownDefaultsSuites: [String] = []

    /// Marks a throwaway UserDefaults suite for deletion of its
    /// `~/Library/Preferences/<suite>.plist`. Why not delete right here:
    /// measured (scratch probe) — cfprefsd writes a dirty domain's plist
    /// ~7–11 s AFTER the last `set`/`removePersistentDomain`, even if the file
    /// was deleted in between (12 of 12 suites reappeared), so `removePersistentDomain`
    /// alone leaves an empty 42-byte plist per suite and an immediate delete
    /// loses the race. The sweep waits for those writes to land, then deletes.
    /// 🔴 Only names under `<bundle id>.tests.` are accepted — never the real
    /// `<bundle id>.plist`.
    static func discardDefaultsSuite(_ suiteName: String) {
        guard suiteName.hasPrefix(AppIdentity.bundleIdentifier + ".tests."),
              !suiteName.contains("/") else {
            assertTrue(false, "discardDefaultsSuite refused a non-test suite name: \(suiteName)")
            return
        }
        knownDefaultsSuites.append(suiteName)
    }

    /// Waits for cfprefsd's delayed writes, then deletes every tracked plist.
    private static func sweepDefaultsSuites() {
        guard !knownDefaultsSuites.isEmpty else { return }
        Thread.sleep(forTimeInterval: 15)
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        for suite in knownDefaultsSuites {
            let plist = prefsDir.appendingPathComponent("\(suite).plist")
            if FileManager.default.fileExists(atPath: plist.path) {
                try? FileManager.default.removeItem(at: plist)
            }
        }
        knownDefaultsSuites.removeAll()
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
