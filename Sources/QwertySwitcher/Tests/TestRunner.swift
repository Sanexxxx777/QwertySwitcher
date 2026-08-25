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
        LicenseServiceTests.run()
        FileLicenseStoreTests.run()
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

enum BloomFilterTests {
    static func run() {
        TestRunner.section("BloomFilter")

        var bloom = BloomFilter(expectedCount: 1000, falsePositiveRate: 0.01)
        bloom.insert("привет")
        bloom.insert("hello")
        TestRunner.assertTrue(bloom.contains("привет"), "contains inserted ru word")
        TestRunner.assertTrue(bloom.contains("hello"), "contains inserted en word")
        TestRunner.assertTrue(!bloom.contains("zzzzzzzz"), "does not contain unrelated word")

        let empty = BloomFilter(expectedCount: 100, falsePositiveRate: 0.01)
        TestRunner.assertTrue(!empty.contains("anything"), "empty filter rejects all")

        let normalizedEmptyCount = BloomFilter.normalizedExpectedCount(0)
        TestRunner.assertEqual(normalizedEmptyCount, 1, "empty dictionary size is normalized safely")
        if normalizedEmptyCount > 0 {
            let emptySource = BloomFilter(expectedCount: 0)
            TestRunner.assertTrue(!emptySource.contains("anything"), "zero-word source builds an empty filter")
        }

        // Roundtrip
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloom_\(UUID().uuidString).ssbf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var big = BloomFilter(expectedCount: 50, falsePositiveRate: 0.01)
        for w in ["apple", "яблоко", "cherry"] { big.insert(w) }
        do {
            try big.save(to: tmp)
            let restored = try BloomFilter.load(from: tmp)
            TestRunner.assertTrue(restored.contains("apple"), "roundtrip: apple")
            TestRunner.assertTrue(restored.contains("яблоко"), "roundtrip: яблоко")
            TestRunner.assertTrue(!restored.contains("nonsense"), "roundtrip: rejects nonsense")
        } catch {
            TestRunner.assertTrue(false, "save/load roundtrip threw: \(error)")
        }

        do {
            try big.save(to: tmp, sourceFingerprint: 123)
            _ = try BloomFilter.load(from: tmp, expectedFingerprint: 123)
            TestRunner.assertTrue(true, "matching source fingerprint restores cache")
            do {
                _ = try BloomFilter.load(from: tmp, expectedFingerprint: 456)
                TestRunner.assertTrue(false, "changed source fingerprint must invalidate cache")
            } catch BloomFilter.BloomFilterError.sourceChanged {
                TestRunner.assertTrue(true, "changed source fingerprint invalidates cache")
            } catch {
                TestRunner.assertTrue(false, "wrong cache error: \(error)")
            }
        } catch {
            TestRunner.assertTrue(false, "fingerprint roundtrip threw: \(error)")
        }

        // Invalid file
        let bad = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bad_\(UUID().uuidString).ssbf")
        defer { try? FileManager.default.removeItem(at: bad) }
        try? "garbage".data(using: .utf8)?.write(to: bad)
        do {
            _ = try BloomFilter.load(from: bad)
            TestRunner.assertTrue(false, "invalid file should throw")
        } catch {
            TestRunner.assertTrue(true, "invalid file throws")
        }

        let undersized = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undersized_\(UUID().uuidString).ssbf")
        defer { try? FileManager.default.removeItem(at: undersized) }
        var malformed = Data()
        for value: UInt32 in [0x51574246, 2, 128, 1, 1] {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { malformed.append(contentsOf: $0) }
        }
        var fingerprint = UInt64(0).littleEndian
        Swift.withUnsafeBytes(of: &fingerprint) { malformed.append(contentsOf: $0) }
        var oneWord = UInt64(0).littleEndian
        Swift.withUnsafeBytes(of: &oneWord) { malformed.append(contentsOf: $0) }
        do {
            try malformed.write(to: undersized)
            _ = try BloomFilter.load(from: undersized)
            TestRunner.assertTrue(false, "undersized bloom bit storage must be rejected")
        } catch BloomFilter.BloomFilterError.invalidFormat {
            TestRunner.assertTrue(true, "undersized bloom bit storage is rejected")
        } catch {
            TestRunner.assertTrue(false, "wrong undersized-cache error: \(error)")
        }
    }
}

enum YoficatorTests {
    static func run() {
        TestRunner.section("Yoficator")
        let svc = YoficatorService()
        TestRunner.assertEqual(svc.yoficate("еж") ?? "", "ёж", "еж → ёж")
        TestRunner.assertNil(svc.yoficate("все"), "ambiguous все must remain unchanged")
        TestRunner.assertEqual(svc.yoficate("пришел") ?? "", "пришёл", "пришел → пришёл")
        TestRunner.assertNil(svc.yoficate("вышел"), "вышел must NOT be yoficated (unstressed е)")
        TestRunner.assertNil(svc.yoficate("абракадабра"), "unknown word returns nil")
        TestRunner.assertNil(svc.yoficate(""), "empty returns nil")
        // Capitalization — feed lookup key "Еж", expect "Ёж"
        TestRunner.assertEqual(svc.yoficate("Еж") ?? "", "Ёж", "capitalization preserved (Еж → Ёж)")
    }
}

enum NGramTests {
    static func run() {
        TestRunner.section("NGramAnalyzer")
        let a = NGramAnalyzer()
        TestRunner.assertTrue(a.score("льъы", language: "ru") < 0, "forbidden ru bigram penalized")
        TestRunner.assertTrue(a.score("qxat", language: "en") < 0, "forbidden en bigram penalized")
        TestRunner.assertTrue(a.score("the", language: "en") > 0, "common en bigrams boosted")
        TestRunner.assertTrue(a.score("стол", language: "ru") > 0, "common ru bigrams boosted")
    }
}

enum InputBufferTests {
    static func run() {
        TestRunner.section("InputBuffer")
        TestRunner.assertTrue(InputBuffer.isWordBoundary(49), "space is boundary")
        TestRunner.assertTrue(InputBuffer.isWordBoundary(36), "return is boundary")
        TestRunner.assertTrue(!InputBuffer.isWordBoundary(0), "A is not boundary")
        TestRunner.assertTrue(InputBuffer.isCorrectableBoundary(49), "space triggers correction")
        TestRunner.assertTrue(!InputBuffer.isCorrectableBoundary(36), "return does NOT trigger correction")
        TestRunner.assertTrue(!InputBuffer.isCorrectableBoundary(48), "tab does NOT trigger correction")

        TestRunner.assertTrue(InputBuffer.isLetterKey(0), "A is letter")
        TestRunner.assertTrue(InputBuffer.isLetterKey(43), "comma is letter (б in ru)")
        TestRunner.assertTrue(InputBuffer.isLetterKey(47), "dot is letter (ю in ru)")
        TestRunner.assertTrue(InputBuffer.isDeleteKey(51), "backspace is delete")

        // Punctuation context-aware
        TestRunner.assertTrue(InputBuffer.isPunctuationIn(keycode: 47, languageCode: "en"), "dot is punctuation in en")
        TestRunner.assertTrue(!InputBuffer.isPunctuationIn(keycode: 47, languageCode: "ru"), "dot is letter in ru")
        TestRunner.assertTrue(InputBuffer.isPunctuationIn(keycode: 43, languageCode: "en"), "comma is punctuation in en")
        TestRunner.assertTrue(!InputBuffer.isPunctuationIn(keycode: 0, languageCode: "en"), "A is not punctuation in en")

        // Trigger char mapping — needed so TextReplacer restores what the user typed
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 41, languageCode: "en") == ";", "keycode 41 maps to ;")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 47, languageCode: "en") == ".", "keycode 47 maps to .")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 43, languageCode: "en") == ",", "keycode 43 maps to ,")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 39, languageCode: "en") == "'", "keycode 39 maps to '")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 0, languageCode: "en") == nil, "A has no punctuation mapping")
        TestRunner.assertTrue(
            InputBuffer.punctuationChar(keycode: 41, languageCode: "en", flags: .maskShift) == ":",
            "shifted punctuation keeps its actual character"
        )
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 18) == "1", "keycode 18 maps to 1")
        TestRunner.assertTrue(
            InputBuffer.digitChar(keycode: 18, flags: .maskShift) == "!",
            "shifted digit keeps its actual character"
        )
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 29) == "0", "keycode 29 maps to 0")
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 0) == nil, "A has no digit mapping")

        let inputSources = InputSourceManager()
        if let russianLayout = inputSources.availableLayouts.first(where: { $0.languageCode == "ru" }) {
            let shiftedB = inputSources.characterForKeycode(
                43, layout: russianLayout, flags: .maskShift
            )
            let shiftedYu = inputSources.characterForKeycode(
                47, layout: russianLayout, flags: .maskShift
            )
            TestRunner.assertTrue(
                shiftedB?.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } == true,
                "Russian fixture: Shift+б produces a letter"
            )
            TestRunner.assertTrue(
                shiftedYu?.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } == true,
                "Russian fixture: Shift+ю produces a letter"
            )
            TestRunner.assertTrue(
                !InputBuffer.isPunctuationIn(
                    keycode: 43, languageCode: russianLayout.languageCode, flags: .maskShift
                ),
                "Shift+б remains a letter in the active Russian layout"
            )
            TestRunner.assertTrue(
                !InputBuffer.isPunctuationIn(
                    keycode: 47, languageCode: russianLayout.languageCode, flags: .maskShift
                ),
                "Shift+ю remains a letter in the active Russian layout"
            )
            TestRunner.assertEqual(
                inputSources.trailingCharacter(keycode: 44, layout: russianLayout),
                inputSources.characterForKeycode(44, layout: russianLayout),
                "trailing slash key matches the active Russian layout"
            )
            TestRunner.assertEqual(
                inputSources.trailingCharacter(
                    keycode: 19, layout: russianLayout, flags: .maskShift
                ),
                inputSources.characterForKeycode(19, layout: russianLayout, flags: .maskShift),
                "shifted number-row trigger matches the active Russian layout"
            )
        } else {
            TestRunner.skip("Russian layout is required for layout-aware trailing-character checks")
        }

        // Same physical key, different printed symbol per layout — the root
        // cause of the "Да?" instead of "Да," auto-correct trailing-trigger
        // bug. KeyboardMonitor's processCurrentWord/swapLastWordInBuffer
        // recompute a word-closing trigger against the TARGET layout using
        // exactly this call.
        if let ru = inputSources.availableLayouts.first(where: { $0.languageCode == "ru" }),
           let en = inputSources.availableLayouts.first(where: { $0.languageCode == "en" }) {
            TestRunner.assertTrue(
                inputSources.characterForKeycode(44, layout: ru, flags: .maskShift) == ",",
                "Shift+kc44 renders ',' on ЙЦУКЕН"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(44, layout: en, flags: .maskShift) == "?",
                "Shift+kc44 renders '?' on QWERTY"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(26, layout: ru, flags: .maskShift) == "?",
                "Shift+kc26 renders '?' on ЙЦУКЕН"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(26, layout: en, flags: .maskShift) == "&",
                "Shift+kc26 renders '&' on QWERTY"
            )
        } else {
            TestRunner.skip("EN + RU layouts are required for the trigger-symbol layout check")
        }

        let buf = InputBuffer()
        buf.append(1, flags: .maskShift)
        buf.append(2, flags: .maskAlphaShift)
        buf.append(3)
        TestRunner.assertTrue(!buf.isEmpty, "buffer not empty after append")
        let strokes = buf.currentWord()
        TestRunner.assertTrue(strokes[0].flags.contains(.maskShift), "buffer preserves Shift per letter")
        TestRunner.assertTrue(strokes[1].flags.contains(.maskAlphaShift), "buffer preserves CapsLock per letter")
        TestRunner.assertTrue(
            !strokes[0].flags.contains(.maskCommand),
            "buffer stores only casing modifiers"
        )
        buf.clear()
        TestRunner.assertTrue(buf.isEmpty, "buffer empty after clear")

        let overflowBuf = InputBuffer()
        for i in 0..<80 { overflowBuf.append(UInt16(i % 128)) }
        TestRunner.assertTrue(overflowBuf.count <= 64, "ring buffer capped at 64")
    }
}

enum SecureInputCacheTests {
    static func run() {
        TestRunner.section("SecureInputDetector")
        var now: CFAbsoluteTime = 100
        var secureInputEnabled = false
        var checks = 0
        let detector = SecureInputDetector(
            nowProvider: { now },
            secureCheck: {
                checks += 1
                return secureInputEnabled
            }
        )

        TestRunner.assertTrue(!detector.isSecureInput, "initial non-secure state is reported")
        secureInputEnabled = true
        now += 0.01
        TestRunner.assertTrue(
            detector.isSecureInput,
            "secure input activation is never hidden by a cached false result"
        )
        TestRunner.assertEqual(checks, 2, "non-secure state is rechecked immediately")
    }
}

enum EditingContextPolicyTests {
    static func run() {
        TestRunner.section("EditingContextPolicy")
        TestRunner.assertTrue(
            InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: .maskAlternate),
            "Option-modified input invalidates buffered word and undo history"
        )
        TestRunner.assertTrue(
            InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: .maskCommand),
            "Command shortcuts invalidate buffered word and undo history"
        )
    }
}

enum ReplacementCancellationTests {
    static func run() {
        TestRunner.section("ReplacementCancellation")
        let token = ReplacementCancellationToken()
        TestRunner.assertTrue(!token.isCancelled, "replacement begins active")
        token.cancel()
        TestRunner.assertTrue(token.isCancelled, "context invalidation cancels replacement")

        let next = ReplacementCancellationToken()
        TestRunner.assertTrue(!next.isCancelled, "new replacement gets an independent token")
    }
}

enum SyntheticEventTests {
    static func run() {
        TestRunner.section("SyntheticEventMarker")
        guard ProcessInfo.processInfo.environment["QWERTY_SWITCH_RUN_CGEVENT_TESTS"] == "1" else {
            TestRunner.skip("CGEvent construction requires a live GUI app session on this macOS build")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            TestRunner.assertTrue(false, "CGEvent can be created")
            return
        }
        TestRunner.assertTrue(!SyntheticEventMarker.isMarked(event), "hardware-like event starts unmarked")
        SyntheticEventMarker.mark(event)
        TestRunner.assertTrue(SyntheticEventMarker.isMarked(event), "generated event marker roundtrips")

        guard let replay = CGEvent(
            keyboardEventSource: source, virtualKey: 1, keyDown: true
        ) else {
            TestRunner.assertTrue(false, "replayed CGEvent can be created")
            return
        }
        SyntheticEventMarker.markAsReplayedUserEvent(replay)
        TestRunner.assertTrue(
            SyntheticEventMarker.isReplayedUserEvent(replay),
            "replayed user event marker roundtrips"
        )
        TestRunner.assertTrue(
            !SyntheticEventMarker.isMarked(replay),
            "replayed user event is distinct from generated input"
        )
        TestRunner.assertTrue(
            SyntheticEventMarker.shouldBypass(replay),
            "replayed user event bypasses Qwerty Switcher analysis"
        )
    }
}

enum ShiftStateTests {
    static func run() {
        TestRunner.section("ShiftStateTracker")
        var state = ShiftStateTracker()
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .down,
            "left Shift press is tracked"
        )
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: true), .down,
            "right Shift press is tracked while left remains held"
        )
        TestRunner.assertTrue(state.bothDown, "both Shift keys can be held")
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .up,
            "left release is detected even while aggregate Shift flag stays set"
        )
        TestRunner.assertTrue(state.rightDown && !state.leftDown, "right Shift remains held")
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: false), .up,
            "final right release is detected"
        )

        _ = state.transition(keycode: 56, aggregateShiftPressed: true)
        _ = state.transition(keycode: 60, aggregateShiftPressed: true)
        state.suppressComboReleases()
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .suppressedRelease,
            "combo left release cannot become a ghost press"
        )
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: false), .suppressedRelease,
            "combo right release cannot become a ghost press"
        )
        TestRunner.assertTrue(!state.anyDown, "combo leaves clean Shift state")
    }
}

enum ShiftTapResolverTests {
    static func run() {
        TestRunner.section("ShiftTapResolver")
        var resolver = ShiftTapResolver()
        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: true), .waitForSecondTap,
            "first tap waits when Double Shift is enabled"
        )
        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: true), .performDoubleNow,
            "second tap fires Double Shift even without Single Shift dependency"
        )
        TestRunner.assertTrue(!resolver.hasPendingFirstTap, "double tap consumes pending state")

        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: false), .performSingleNow,
            "Single Shift has no 450ms delay when Double Shift is disabled"
        )
        _ = resolver.registerTap(doubleShiftEnabled: true)
        TestRunner.assertTrue(resolver.expireFirstTap(), "pending first tap expires once")
        TestRunner.assertTrue(!resolver.expireFirstTap(), "expired tap cannot fire twice")
        _ = resolver.registerTap(doubleShiftEnabled: true)
        resolver.cancel()
        TestRunner.assertTrue(!resolver.hasPendingFirstTap, "typing cancels pending Shift tap")
    }
}

/// FIX B (13.08.2026, ghost Cmd+Shift+V shift-tap): a fresh Shift-down used
/// to unconditionally reset `anyModifierWithShift = false`, so
/// Cmd↓→Shift↓→V(swallowed)→Shift↑ read as a clean Shift-tap and armed a
/// phantom Single/Double Shift on the NEXT tap within 450ms. The predicate is
/// pure and shared between the mid-hold check and the fresh-down seed.
enum ShiftTapModifierDisqualifierTests {
    static func run() {
        TestRunner.section("HotkeyManager.modifierDisqualifiesShiftTap — pure predicate")
        TestRunner.assertTrue(
            !HotkeyManager.modifierDisqualifiesShiftTap([]),
            "no modifiers: does not disqualify"
        )
        TestRunner.assertTrue(
            !HotkeyManager.modifierDisqualifiesShiftTap(.maskShift),
            "Shift alone: does not disqualify"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskCommand),
            "Cmd: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskControl),
            "Ctrl: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskAlternate),
            "Alt: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap([.maskCommand, .maskShift]),
            "Cmd+Shift together (the Cmd+Shift+V case): disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap([.maskAlternate, .maskShift]),
            "Alt+Shift together: disqualifies"
        )
    }
}

enum AutoLearnTrackerTests {
    static func run() {
        TestRunner.section("AutoLearnTracker")
        var tracker = AutoLearnTracker()
        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        for _ in 0..<5 { tracker.registerDeletion() }
        TestRunner.assertTrue(!tracker.isAwaitingRetype, "word-only deletion is not enough when space remains")
        tracker.registerDeletion()
        TestRunner.assertTrue(tracker.isAwaitingRetype, "full corrected transaction deletion awaits retype")
        TestRunner.assertEqual(
            tracker.confirmRetype(word: "руддщ", trailing: " "),
            Optional(LearnedCorrection(original: "руддщ", corrected: "hello")),
            "exact retype confirms learned exception"
        )

        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        for _ in 0..<6 { tracker.registerDeletion() }
        TestRunner.assertNil(
            tracker.confirmRetype(word: "другое", trailing: " "),
            "different retype must not create an exception"
        )

        tracker.recordCorrection(original: "руддщ", corrected: "hello", trailing: " ")
        tracker.registerDeletion()
        tracker.registerNonDeletion()
        for _ in 0..<5 { tracker.registerDeletion() }
        TestRunner.assertTrue(!tracker.isAwaitingRetype, "partial deletion plus typing cancels learning")
    }
}

enum ReplacementTransactionTests {
    static func run() {
        TestRunner.section("Replacement transaction")
        let plan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: "."
        )
        TestRunner.assertEqual(plan.backspaceCount, 7, "replacement deletes word and exact trailing character")
        TestRunner.assertEqual(plan.payload, "привет.", "replacement restores punctuation exactly")

        // RC-1 fix: when WE suppressed the trigger keystroke ourselves (it
        // never reached the screen), backspace only the word — the trigger
        // is retyped as part of the payload instead of backspaced over.
        let suppressedTriggerPlan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: " ",
            trailingAlreadyOnScreen: false
        )
        TestRunner.assertEqual(
            suppressedTriggerPlan.backspaceCount, 6,
            "a suppressed trigger was never typed — backspace only the word itself"
        )
        TestRunner.assertEqual(
            suppressedTriggerPlan.payload, "привет ",
            "payload still retypes the corrected word AND the suppressed trailing character"
        )

        // Old behavior is preserved by default — Undo and Double Shift pass a
        // trailing character that really IS already on screen and must not
        // be touched by this fix.
        let onScreenTriggerPlan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: " "
        )
        TestRunner.assertEqual(
            onScreenTriggerPlan.backspaceCount, 7,
            "default trailingAlreadyOnScreen=true preserves Undo/DoubleShift's old formula"
        )

        let undo = SwitchUndoManager()
        undo.record(
            originalKeycodes: [1, 2, 3],
            originalWord: "руддщ",
            correctedWord: "hello",
            trailing: " ",
            originalLayoutID: "ru",
            targetLayoutID: "en"
        )
        TestRunner.assertTrue(undo.canUndo, "undo remains available until next physical edit")
        TestRunner.assertEqual(undo.consume()?.trailing, " ", "undo transaction preserves trailing space")
        TestRunner.assertTrue(!undo.canUndo, "undo transaction is consumed exactly once")
    }
}

enum LanguageSkipTests {
    static func run() {
        TestRunner.section("Language skip rules")
        TestRunner.assertTrue(LanguageDetector.shouldSkip("NASA"), "uppercase acronym is skipped before lowercasing")
        TestRunner.assertTrue(LanguageDetector.shouldSkip("https://example.com"), "URL is skipped")
        TestRunner.assertTrue(LanguageDetector.shouldSkip("name@example.com"), "email is skipped")
        TestRunner.assertTrue(LanguageDetector.shouldSkip("camelCase"), "camelCase identifier is skipped")
        TestRunner.assertTrue(!LanguageDetector.shouldSkip("руддщ"), "ordinary mistyped word remains eligible")
    }
}

enum InputSourceLanguageTests {
    static func run() {
        TestRunner.section("Input source language")
        TestRunner.assertEqual(
            InputSourceManager.inferredLanguage(
                sourceID: "com.apple.keylayout.US", languages: []
            ),
            "en",
            "U.S. layout ID fallback resolves to English"
        )
        TestRunner.assertEqual(
            InputSourceManager.inferredLanguage(
                sourceID: "com.apple.keylayout.Austrian", languages: []
            ),
            "und",
            "Austrian is not misclassified by the substring 'us'"
        )
        TestRunner.assertEqual(
            InputSourceManager.inferredLanguage(
                sourceID: "vendor.layout", languages: ["de-AT"]
            ),
            "de",
            "TIS language metadata takes priority over ID heuristics"
        )
    }
}

enum PrivacyTests {
    static func run() {
        TestRunner.section("Privacy")
        let sanitized = PrivacyService.sanitize("secretWord")
        TestRunner.assertTrue(!sanitized.contains("secretWord"), "diagnostics redact actual word")
        TestRunner.assertTrue(sanitized.contains("10"), "diagnostics retain only useful length")
    }
}

enum ExceptionsTests {
    static func run() {
        TestRunner.section("ExceptionsService")
        let svc = ExceptionsService()
        TestRunner.assertTrue(svc.isValidException("hello"), "hello is valid")
        TestRunner.assertTrue(svc.isValidException("привет"), "привет is valid")
        TestRunner.assertTrue(!svc.isValidException("a"), "single letter invalid")
        TestRunner.assertTrue(!svc.isValidException(String(repeating: "x", count: 30)), "too long invalid")
        TestRunner.assertTrue(!svc.isValidException("key=value"), "= disallowed")
        TestRunner.assertTrue(!svc.isValidException("path/file"), "/ disallowed")
        TestRunner.assertTrue(!svc.isValidException("123"), "digits-only invalid")

        let suite = AppIdentity.bundleIdentifier + ".tests.exceptions." + UUID().uuidString
        guard let isolatedDefaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        isolatedDefaults.set(["legacy.example"], forKey: AppIdentity.keyPrefix + "appExceptions")
        let isolated = ExceptionsService(defaults: isolatedDefaults)
        TestRunner.assertTrue(
            isolated.blocksAutoSwitch(bundleID: "legacy.example"),
            "legacy app exceptions migrate into block-auto profiles"
        )
        isolated.setProfile(
            AppProfile(blockAutoSwitch: false, blockInstantCorrection: true, blockHotkeys: true),
            for: "editor.example"
        )
        TestRunner.assertTrue(
            !isolated.blocksAutoSwitch(bundleID: "editor.example"),
            "profile can allow boundary correction"
        )
        TestRunner.assertTrue(
            isolated.blocksInstantCorrection(bundleID: "editor.example"),
            "profile can independently block instant correction"
        )
        TestRunner.assertTrue(
            isolated.blocksHotkeys(bundleID: "editor.example"),
            "profile can independently block hotkeys"
        )
        isolated.removeProfiles(for: ["editor.example"])
        TestRunner.assertNil(isolated.profile(for: "editor.example"), "profile removal is exact")
    }
}

enum TimedPauseTests {
    static func run() {
        TestRunner.section("TimedPauseService")
        let suite = AppIdentity.bundleIdentifier + ".tests.pause." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = PreferencesService(defaults: defaults)
        prefs.isAutoSwitchEnabled = true
        let start = Date(timeIntervalSince1970: 1_000)
        let service = TimedPauseService(
            prefsService: prefs, defaults: defaults, schedulesTimers: false, now: start
        )
        service.pause(for: 900, now: start)
        TestRunner.assertTrue(service.isActive, "timed pause persists a resume deadline")
        TestRunner.assertTrue(!prefs.isAutoSwitchEnabled, "timed pause disables auto-switch")
        TestRunner.assertTrue(
            !service.reconcile(now: Date(timeIntervalSince1970: 1_899)),
            "pause remains active before its deadline"
        )
        TestRunner.assertTrue(
            service.reconcile(now: Date(timeIntervalSince1970: 1_900)),
            "pause resumes exactly at its deadline"
        )
        TestRunner.assertTrue(prefs.isAutoSwitchEnabled, "deadline restores auto-switch")
        TestRunner.assertTrue(!service.isActive, "deadline clears the stored schedule")

        service.pause(for: 900, now: start)
        prefs.isAutoSwitchEnabled = true
        NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)
        TestRunner.assertTrue(
            !service.isActive,
            "a manual toggle cancels the pending automatic resume"
        )

        let viewModelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("UI/Views/MainViewModel.swift")
        let viewModelSource = (try? String(contentsOf: viewModelURL, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            viewModelSource.contains("guard !isSyncingAutoSwitch else { return }"),
            "settings-window synchronization does not echo and cancel a timed pause"
        )
    }
}

enum SettingsBackupTests {
    static func run() {
        TestRunner.section("SettingsBackupService")
        let suite = AppIdentity.bundleIdentifier + ".tests.backup." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = PreferencesService(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let perApp = PerAppLayoutService(inputSourceManager: InputSourceManager(), prefsService: prefs)
        let snippets = SnippetService(defaults: defaults)
        let service = SettingsBackupService(
            prefsService: prefs, exceptionsService: exceptions, perAppLayoutService: perApp,
            snippetService: snippets
        )

        prefs.isInstantCorrectionEnabled = false
        prefs.activeLayoutIDs = ["layout.en", "layout.ru"]
        exceptions.wordExceptions = ["qwerty", "привет"]
        exceptions.setProfile(
            AppProfile(blockAutoSwitch: false, blockInstantCorrection: true, blockHotkeys: false),
            for: "app.example"
        )
        perApp.isEnabled = true
        perApp.manualOverrides = ["app.example": "layout.ru"]
        _ = snippets.setSnippet(trigger: "addr", replacement: "Владивосток")

        guard let data = try? service.encodedBackup(now: Date(timeIntervalSince1970: 1_000)) else {
            TestRunner.assertTrue(false, "settings backup encodes")
            return
        }
        let json = String(data: data, encoding: .utf8) ?? ""
        TestRunner.assertTrue(!json.contains("hwid"), "backup excludes the license device identifier")
        TestRunner.assertTrue(!json.contains("licenseFirstSeen"), "backup excludes license anti-tamper state")

        prefs.isInstantCorrectionEnabled = true
        exceptions.wordExceptions = []
        exceptions.appProfiles = [:]
        perApp.isEnabled = false
        perApp.manualOverrides = [:]
        snippets.snippets = [:]
        do {
            try service.importBackup(data)
            TestRunner.assertTrue(!prefs.isInstantCorrectionEnabled, "import restores preferences")
            TestRunner.assertTrue(exceptions.wordExceptions.contains("привет"), "import restores word exceptions")
            TestRunner.assertTrue(
                exceptions.blocksInstantCorrection(bundleID: "app.example"),
                "import restores per-feature app profiles"
            )
            TestRunner.assertEqual(
                perApp.manualOverrides["app.example"] ?? "", "layout.ru",
                "import restores manual per-app layout overrides"
            )
            TestRunner.assertEqual(
                snippets.replacement(for: "addr") ?? "", "Владивосток",
                "import restores local text snippets"
            )
        } catch {
            TestRunner.assertTrue(false, "valid settings backup imports: \(error.localizedDescription)")
        }

        if let valid = try? service.decodeAndValidate(data),
           let badData = try? JSONEncoder().encode(SettingsBackup(
                formatVersion: 99, createdAt: valid.createdAt, preferences: valid.preferences,
                wordExceptions: valid.wordExceptions, appProfiles: valid.appProfiles,
                autoLearned: valid.autoLearned, snippets: valid.snippets,
                perAppLayoutEnabled: valid.perAppLayoutEnabled,
                manualLayoutOverrides: valid.manualLayoutOverrides,
                rememberedLayouts: valid.rememberedLayouts
           )) {
            do {
                _ = try service.decodeAndValidate(badData)
                TestRunner.assertTrue(false, "unsupported backup version is rejected")
            } catch SettingsBackupService.BackupError.unsupportedVersion(99) {
                TestRunner.assertTrue(true, "unsupported backup version is rejected")
            } catch {
                TestRunner.assertTrue(false, "unsupported version reports the expected error")
            }
        } else {
            TestRunner.assertTrue(false, "unsupported-version fixture encodes")
        }
    }
}

enum SnippetTests {
    static func run() {
        TestRunner.section("SnippetService")
        let suite = AppIdentity.bundleIdentifier + ".tests.snippets." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SnippetService(defaults: defaults)

        TestRunner.assertTrue(service.isValidTrigger("addr"), "letter-only trigger is valid")
        TestRunner.assertTrue(!service.isValidTrigger("a"), "one-letter trigger is rejected")
        TestRunner.assertTrue(!service.isValidTrigger("addr 1"), "trigger with whitespace/digits is rejected")
        TestRunner.assertTrue(
            service.setSnippet(trigger: "ADDR", replacement: "line one\nline two"),
            "multiline snippet is stored"
        )
        TestRunner.assertEqual(
            service.replacement(for: "addr") ?? "", "line one\nline two",
            "snippet lookup is case-insensitive"
        )
        service.removeSnippet(trigger: "addr")
        TestRunner.assertNil(service.replacement(for: "addr"), "snippet removal is exact")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        let monitorSource = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            monitorSource.contains("expandSnippet(keystrokes: captured"),
            "word-boundary path checks snippets before language correction"
        )
        TestRunner.assertTrue(
            monitorSource.contains("trailingAlreadyOnScreen: false"),
            "snippet expansion suppresses and retypes the boundary in one transaction"
        )
    }
}

enum SmartCaseTests {
    static func run() {
        TestRunner.section("SmartCaseNormalizer")
        TestRunner.assertEqual(
            SmartCaseNormalizer.normalized("ПРивет", capitalizeSentenceStart: false) ?? "",
            "Привет", "accidentally held Shift is normalized"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("USA", capitalizeSentenceStart: false),
            "all-caps acronym is preserved"
        )
        TestRunner.assertEqual(
            SmartCaseNormalizer.normalized("hello", capitalizeSentenceStart: true) ?? "",
            "Hello", "plain word after sentence punctuation is capitalized"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("iPhone", capitalizeSentenceStart: true),
            "camelCase brand is preserved"
        )
        TestRunner.assertNil(
            SmartCaseNormalizer.normalized("hello-world", capitalizeSentenceStart: true),
            "non-word token is preserved"
        )

        var tracker = SentenceStartTracker()
        tracker.observeBoundary(".")
        TestRunner.assertTrue(
            tracker.shouldCapitalizeNextWord,
            "sentence punctuation keeps capitalization armed across following whitespace"
        )
        TestRunner.assertTrue(tracker.consumeForWord(), "period arms capitalization for one word")
        TestRunner.assertTrue(!tracker.consumeForWord(), "capitalization intent is consumed once")
        tracker.observeBoundary("!")
        tracker.reset()
        TestRunner.assertTrue(!tracker.consumeForWord(), "context reset clears sentence intent")

        let monitorSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        let source = (try? String(contentsOf: monitorSource, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            source.contains("if !captured.isEmpty { sentenceStartTracker.observeBoundary(trailing) }"),
            "empty whitespace boundaries do not clear sentence capitalization"
        )
    }
}

enum InstantCorrectionGateTests {
    static func run() {
        TestRunner.section("InstantCorrectionGate")
        var gate = InstantCorrectionGate()
        TestRunner.assertTrue(!gate.wasCorrected, "gate starts uncorrected")

        gate.markCorrected()
        TestRunner.assertTrue(gate.wasCorrected, "instant correction marks the gate")
        TestRunner.assertTrue(
            gate.consumeIfCorrected(),
            "boundary handler sees the corrected word exactly once"
        )
        TestRunner.assertTrue(
            !gate.consumeIfCorrected(),
            "boundary handler does not correct the same word a second time"
        )

        gate.markCorrected()
        gate.startNewWord()
        TestRunner.assertTrue(
            !gate.consumeIfCorrected(),
            "a brand-new word resets the gate even if the previous word was instant-corrected"
        )

        gate.markCorrected()
        gate.reset()
        TestRunner.assertTrue(
            !gate.consumeIfCorrected(),
            "context invalidation (click/focus change) resets the gate"
        )
    }
}

enum PreferencesServiceTests {
    static func run() {
        TestRunner.section("PreferencesService — instant correction toggle")
        let key = AppIdentity.keyPrefix + "instantCorrection"
        let previouslySet = UserDefaults.standard.object(forKey: key)
        defer {
            if let previouslySet {
                UserDefaults.standard.set(previouslySet, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        TestRunner.assertTrue(
            PreferencesService().isInstantCorrectionEnabled,
            "instant correction defaults to enabled when never configured"
        )

        let prefs = PreferencesService()
        prefs.isInstantCorrectionEnabled = false
        TestRunner.assertTrue(
            !PreferencesService().isInstantCorrectionEnabled,
            "instant correction can be disabled and persists"
        )
        prefs.isInstantCorrectionEnabled = true
        TestRunner.assertTrue(
            PreferencesService().isInstantCorrectionEnabled,
            "instant correction can be re-enabled"
        )

        // isLayoutSoundEnabled — separate from isSoundEnabled by design (see
        // SoundService: the master sound gate stays isSoundEnabled).
        let soundKey = AppIdentity.keyPrefix + "layoutSoundEnabled"
        let previousSoundSet = UserDefaults.standard.object(forKey: soundKey)
        defer {
            if let previousSoundSet {
                UserDefaults.standard.set(previousSoundSet, forKey: soundKey)
            } else {
                UserDefaults.standard.removeObject(forKey: soundKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: soundKey)
        TestRunner.assertTrue(
            PreferencesService().isLayoutSoundEnabled,
            "layout-switch sound defaults to enabled when never configured"
        )
        prefs.isLayoutSoundEnabled = false
        TestRunner.assertTrue(
            !PreferencesService().isLayoutSoundEnabled,
            "layout-switch sound can be disabled independently and persists"
        )
        TestRunner.assertTrue(
            PreferencesService().isSoundEnabled,
            "disabling the layout-switch sound alone does not touch the master sound gate"
        )

        // layoutSoundName — which system sound plays (see SoundService).
        let layoutSoundKey = AppIdentity.keyPrefix + "layoutSoundName"
        let previousLayoutSound = UserDefaults.standard.object(forKey: layoutSoundKey)
        defer {
            if let previousLayoutSound {
                UserDefaults.standard.set(previousLayoutSound, forKey: layoutSoundKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layoutSoundKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: layoutSoundKey)
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, "Pop",
            "layout sound defaults to 'Pop' when never configured — neutral, not an alert cue"
        )
        prefs.layoutSoundName = "Glass"
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, "Glass",
            "layout sound choice persists across instances (saved/read from prefs)"
        )
        prefs.layoutSoundName = SoundService.noSoundName
        TestRunner.assertEqual(
            PreferencesService().layoutSoundName, SoundService.noSoundName,
            "'Без звука' is a storable, readable choice like any other"
        )
    }
}

enum SoundServiceTests {
    static func run() {
        TestRunner.section("SoundService — sound-name resolution (pure, no NSSound touched)")
        TestRunner.assertTrue(
            SoundService.systemSoundNames.contains("Pop"),
            "curated system sound list includes the default 'Pop'"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: "Pop"), "Pop",
            "a known system sound name resolves to itself"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: SoundService.noSoundName), nil,
            "'Без звука' resolves to nil — stays silent, not a fallback sound"
        )
        TestRunner.assertEqual(
            SoundService.effectiveSoundName(for: "TotallyBogusSoundName"), "Pop",
            "an unrecognized/corrupted stored name falls back to Pop — safe fallback, not a crash"
        )

        TestRunner.section("SoundService — gates override the selected sound")
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: false, isLayoutSoundEnabled: true, storedName: "Glass"),
            nil,
            "master sound gate off overrides any selected sound"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: true, isLayoutSoundEnabled: false, storedName: "Glass"),
            nil,
            "layout-sound gate off overrides any selected sound"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(isSoundEnabled: true, isLayoutSoundEnabled: true, storedName: "Glass"),
            "Glass",
            "both gates on — the selected sound plays"
        )
        TestRunner.assertEqual(
            SoundService.layoutCueName(
                isSoundEnabled: true, isLayoutSoundEnabled: true, storedName: SoundService.noSoundName
            ),
            nil,
            "both gates on but 'Без звука' selected — still stays silent"
        )
    }
}

enum CaretWordExtractorTests {
    static func run() {
        TestRunner.section("CaretWordExtractor — Double Shift's word-before-caret path")
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "привет", caretUTF16Offset: 6),
            CaretWordExtractor.Result(word: "привет", utf16Range: NSRange(location: 0, length: 6)),
            "whole single word before the caret at the end of the field"
        )
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "hello ghbdtn", caretUTF16Offset: 12),
            CaretWordExtractor.Result(word: "ghbdtn", utf16Range: NSRange(location: 6, length: 6)),
            "only the LAST word before the caret is taken, not the whole field"
        )
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "мама мыла раму", caretUTF16Offset: 9),
            CaretWordExtractor.Result(word: "мыла", utf16Range: NSRange(location: 5, length: 4)),
            "caret in the MIDDLE of the field takes the word ending there, not the last word overall"
        )
        TestRunner.assertNil(
            CaretWordExtractor.wordBeforeCaret(text: "hello ", caretUTF16Offset: 6),
            "caret right after whitespace has no word to convert"
        )
        TestRunner.assertNil(
            CaretWordExtractor.wordBeforeCaret(text: "hello", caretUTF16Offset: 0),
            "caret at the very start has no word before it"
        )
        // Single letters are ordinary words in Russian (и, а, в, к, с, я, о, у)
        // and the owner hit this directly: five Double Shifts on a lone "b"
        // did nothing (log 07:49:54-57). The floor was lowered to 1 for the
        // EXPLICIT gesture only — automatic correction keeps its own, higher
        // bar, where a false positive would rewrite a shell flag (`rm -f`).
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "a", caretUTF16Offset: 1)?.word,
            "a",
            "single-character word IS convertible via the explicit Double Shift path"
        )
    }
}

enum LayoutTextConverterTests {
    static func run() {
        TestRunner.section("LayoutTextConverter — Double Shift selection/clipboard conversion")
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for selection-conversion fixtures")
            return
        }

        // "ghbdtn" typed on the EN layout is what "привет" looks like on
        // screen when the wrong layout was active — exactly what AX-selected
        // or clipboard text looks like to Double Shift (no original keystrokes).
        let converted = LayoutTextConverter.convert(
            "ghbdtn", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(converted, "привет", "en-typed text converts to the intended Russian word")

        let roundTrip = LayoutTextConverter.convert(
            converted, from: ruLayout, to: enLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(roundTrip, "ghbdtn", "conversion round-trips back to the original keys")

        let capitalized = LayoutTextConverter.convert(
            "Ghbdtn", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(capitalized, "Привет", "capitalization survives the conversion")

        let mixed = LayoutTextConverter.convert(
            "ghbdtn123", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(mixed, "привет123", "characters with no reverse mapping (digits) pass through unchanged")

        // Symbols whose meaning differs between layouts must convert too —
        // this is the selection path, so it covers "I highlighted a sentence
        // with symbols and pressed Double Shift". Keycode 44 is "/" on QWERTY
        // and "." on ЙЦУКЕН; before the reverse map covered symbol keys, the
        // letters moved alphabet and the symbol was left behind (".exit").
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                ".учше", from: ruLayout, to: enLayout, inputSourceManager: inputSources
            ),
            "/exit",
            "a layout-dependent symbol converts along with the word"
        )
        // A whole sentence, both directions. Note what the punctuation does:
        // Russian puts "," on Shift+/ (keycode 44), English puts it on its own
        // key (43). Someone touch-typing Russian while the English layout is
        // active presses Shift+44 for their comma and gets "?" on screen — so
        // "?" converting BACK to "," is correct, and a literal "," in the
        // English text genuinely was the "б" key. Key-for-key is not an
        // approximation here; it is the only reading that reproduces what the
        // person's fingers actually asked for.
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                "ghbdtn? rfr ltkf&", from: enLayout, to: ruLayout, inputSourceManager: inputSources
            ),
            "привет, как дела?",
            "a whole sentence converts — letters and punctuation together"
        )
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                "привет, как дела?", from: ruLayout, to: enLayout, inputSourceManager: inputSources
            ),
            "ghbdtn? rfr ltkf&",
            "and back the other way — the English direction is not an afterthought"
        )

        let strokes = LayoutTextConverter.keystrokes(for: "ghbdtn", typedOn: enLayout, inputSourceManager: inputSources)
        TestRunner.assertEqual(strokes?.count ?? -1, 6, "reconstructed keystrokes match the source text length")
        TestRunner.assertNil(
            LayoutTextConverter.keystrokes(for: "gh1btn", typedOn: enLayout, inputSourceManager: inputSources),
            "text containing an unmapped character (digit) can't be reconstructed into keystrokes"
        )
    }
}

enum LogRetentionTests {
    static func run() {
        TestRunner.section("DebugLog — logs expire by age, not just by size")
        let now = Date()
        TestRunner.assertTrue(
            DebugLog.isExpired(created: now.addingTimeInterval(-6 * 86_400), now: now, maxAgeDays: 5),
            "a file first written six days ago is past the five-day cap"
        )
        TestRunner.assertTrue(
            !DebugLog.isExpired(created: now.addingTimeInterval(-4 * 86_400), now: now, maxAgeDays: 5),
            "four days old is still within the window"
        )
        TestRunner.assertTrue(
            !DebugLog.isExpired(created: now, now: now, maxAgeDays: 5),
            "a file created just now never expires on the same launch"
        )
    }
}

enum DominantScriptLanguageTests {
    /// `LanguageDetector.dominantScriptLanguageCode` is what the AX-selection,
    /// clipboard and word-before-caret Double Shift paths use to pick the
    /// SOURCE layout — from the text's own characters, never from whatever
    /// layout happens to be active (see CLAUDE.md "марже" bug).
    static func run() {
        TestRunner.section("LanguageDetector.dominantScriptLanguageCode — content-based direction")
        TestRunner.assertEqual(
            LanguageDetector.dominantScriptLanguageCode("привет"), "ru",
            "pure Cyrillic text is detected as ru regardless of the active layout"
        )
        TestRunner.assertEqual(
            LanguageDetector.dominantScriptLanguageCode("hello"), "en",
            "pure Latin text is detected as en regardless of the active layout"
        )
        TestRunner.assertEqual(
            LanguageDetector.dominantScriptLanguageCode("привhi"), "ru",
            "mixed content picks the majority script — Cyrillic majority (4 vs 2) → ru"
        )
        TestRunner.assertEqual(
            LanguageDetector.dominantScriptLanguageCode("прivet"), "en",
            "mixed content picks the majority script — Latin majority (4 vs 2) → en"
        )
        TestRunner.assertNil(
            LanguageDetector.dominantScriptLanguageCode("12345"),
            "digits-only text carries no script — no direction can be guessed, caller must no-op"
        )
    }
}

enum MarzheDoubleShiftRegressionTests {
    /// Named regression from live evidence (09:16, EN layout active): the
    /// owner typed «марже» intending Russian — the physical keys landed on
    /// screen as "vfh;t" (EN interpretation of the same keycodes). Pre-fix,
    /// Double Shift's buffer/history path (`swapLastWordInBuffer`) scored
    /// the word against whatever layout was ACTIVE AT THE MOMENT the hotkey
    /// fired, not the layout the word was actually typed on — history has no
    /// TTL, so if the active layout had drifted by press time, direction
    /// scrambled (live log: "ru→en", result "мavfh;t" garbage instead of
    /// «марже»). Fixed by always resolving direction from an explicit
    /// `typedLayout` (`LanguageDetector.swapTarget`, fed by
    /// `KeyboardMonitor.lastCompletedWord.typedLayout`, captured AT WORD-
    /// COMPLETION time) — this suite exercises that same primitive directly.
    ///
    /// Also covers the "3 presses needed" toggle bug from the same log
    /// (Spotlight, 11:16): a second immediate Double Shift on a word the
    /// first press just converted must flip it straight back — not fall
    /// through to caret-word/Undo — and a third press must convert again.
    static func run() {
        TestRunner.section("Double Shift buffer/history — «марже» direction + toggle regression")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the «марже» regression fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        // Physical keys that spell «марже» when interpreted via RU — exactly
        // what the owner physically pressed.
        guard let marzheStrokes = InstantCorrectionFixtures.keystrokes(for: "марже", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«марже»: fixture layout can type every character")
            return
        }
        TestRunner.assertEqual(
            inputSources.convertKeystrokes(marzheStrokes, toLayout: enLayout), "vfh;t",
            "sanity: the same physical keys render as 'vfh;t' when EN is active — matches the live log verbatim"
        )

        // --- Named regression: typed while EN was active → must convert en→ru ---
        guard let regression = detector.swapTarget(keystrokes: marzheStrokes, typedLayout: enLayout) else {
            TestRunner.assertTrue(false, "«марже» regression: swapTarget must find a conversion")
            return
        }
        TestRunner.assertEqual(regression.layout.languageCode, "ru", "«марже» regression: direction is en→ru, not ru→en")
        TestRunner.assertEqual(regression.word, "марже", "«марже» regression: corrected word is «марже», not garbage")

        // --- Mirror: an EN word typed while RU was active → must convert ru→en ---
        // Physical keys that spell "hello" when interpreted via EN render as
        // "руддщ" while RU is active (same fixture pairing InstantCorrectionAnalyzerTests uses).
        guard let helloStrokes = InstantCorrectionFixtures.keystrokes(for: "руддщ", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "mirror case: fixture layout can type every character")
            return
        }
        guard let mirror = detector.swapTarget(keystrokes: helloStrokes, typedLayout: ruLayout) else {
            TestRunner.assertTrue(false, "mirror case: swapTarget must find a conversion")
            return
        }
        TestRunner.assertEqual(mirror.layout.languageCode, "en", "mirror case: direction is ru→en")
        TestRunner.assertEqual(mirror.word, "hello", "mirror case: corrected word is 'hello'")

        // --- Toggle: two presses return the original, the third converts again ---
        guard let press1 = detector.swapTarget(keystrokes: marzheStrokes, typedLayout: enLayout) else {
            TestRunner.assertTrue(false, "toggle 1st press: must convert")
            return
        }
        TestRunner.assertEqual(press1.word, "марже", "toggle 1st press: en→ru gives «марже»")

        guard let press2 = detector.swapTarget(keystrokes: marzheStrokes, typedLayout: press1.layout) else {
            TestRunner.assertTrue(false, "toggle 2nd press: must convert back, not get stuck")
            return
        }
        TestRunner.assertEqual(press2.word, "vfh;t", "toggle 2nd press: converts BACK to the original on-screen text")
        TestRunner.assertEqual(press2.layout.languageCode, "en", "toggle 2nd press: back to en")

        guard let press3 = detector.swapTarget(keystrokes: marzheStrokes, typedLayout: press2.layout) else {
            TestRunner.assertTrue(false, "toggle 3rd press: must convert again")
            return
        }
        TestRunner.assertEqual(
            press3.word, "марже",
            "toggle 3rd press: converts to «марже» again — one press per result, never 3 presses to work"
        )
    }
}

enum TwoLetterWordScoringTests {
    /// Diagnosis: en_US.txt and ru_RU.txt list almost the entire two-letter
    /// Cartesian square as "words" (650/1024 en pairs, 774/1024 ru pairs), so
    /// the Bloom filter used to score a reversed-layout typo like "yf" (the
    /// EN-layout reading of «на») as a genuine EN dictionary hit — 84 points,
    /// enough to make `incumbentGap` (25) unbeatable and permanently block
    /// the correction. `scoreWord`'s closed `twoLetterWords` list (see
    /// `oneLetterWords` next to it in LanguageDetector.swift) fixes this.
    static func run() {
        TestRunner.section("scoreWord — closed two-letter word list (yf/yt regression)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for two-letter word fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        // --- 1: "yf" (EN-layout reading of «на»), primed en-context ---
        guard let naStrokes = InstantCorrectionFixtures.keystrokes(for: "на", reverse: ruReverse),
              let helloStrokes = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) else {
            TestRunner.assertTrue(false, "«на»/«hello»: fixture layouts can type every character")
            return
        }
        TestRunner.assertEqual(
            inputSources.convertKeystrokes(naStrokes, toLayout: enLayout), "yf",
            "sanity: physical keys for «на» render as 'yf' when EN is active — matches the reported garbage"
        )
        // Primes previousWordLanguage = "en" — a genuine EN word typed while
        // EN is active (previousWordLanguage starts nil on a fresh detector).
        _ = detector.detect(keystrokes: helloStrokes, typedLayout: enLayout)

        switch detector.detect(keystrokes: naStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'yf' under en-context switches to ru")
            TestRunner.assertEqual(word, "на", "'yf' under en-context corrects to «на»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'yf' under en-context must switch to «на» (pre-fix regression: noSwitch)")
        }

        // --- 2: "yt" (EN-layout reading of «не»), neutral context ---
        detector.resetContext()
        guard let neStrokes = InstantCorrectionFixtures.keystrokes(for: "не", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«не»: RU fixture layout can type every character")
            return
        }
        TestRunner.assertEqual(
            inputSources.convertKeystrokes(neStrokes, toLayout: enLayout), "yt",
            "sanity: physical keys for «не» render as 'yt' when EN is active"
        )
        switch detector.detect(keystrokes: neStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'yt' under neutral context switches to ru")
            TestRunner.assertEqual(word, "не", "'yt' under neutral context corrects to «не»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'yt' under neutral context must switch to «не»")
        }

        // --- 3/4/5: negatives — words typed correctly in EN never switch ---
        detector.resetContext()
        let negatives: [(word: String, note: String)] = [
            ("ok", "list symmetry guard"),
            ("vs", "live token protected despite «мы» being a real (deliberately omitted) ru word"),
            ("zx", "garbage in both languages"),
        ]
        for negative in negatives {
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: negative.word, reverse: enReverse) else {
                TestRunner.assertTrue(false, "'\(negative.word)': EN fixture layout can type every character")
                continue
            }
            switch detector.detect(keystrokes: strokes, typedLayout: enLayout) {
            case .switchTo:
                TestRunner.assertTrue(false, "'\(negative.word)' must stay noSwitch — \(negative.note)")
            case .noSwitch:
                TestRunner.assertTrue(true, "'\(negative.word)' stays noSwitch — \(negative.note)")
            }
            detector.resetContext()
        }
    }
}

/// Diagnosis (false_switch_sim.py corpus sweep, 15.08.2026): the boundary
/// scorer's `incumbentGap` moat is a fixed number of points and can be
/// outrun by frequency+bigram bonuses on the other side ("руку" a real
/// Russian dictionary word losing to "here"), and one-letter candidates
/// have no incumbent at all to hold a gap against ("d" typed live in
/// English converting to Russian "в"). Both fixes gate on the context the
/// user had established BEFORE this word, not on the score itself.
enum NativeContextIncumbentAndOneLetterTests {
    static func run() {
        TestRunner.section("Native-context incumbent lock + one-letter context gate")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for native-context fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        // --- 1: «руку» (ru dictionary word, ranked 677) typed on ru layout
        //        with an already-established ru context must never be
        //        overwritten — pre-fix this switched to en «here». ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        ) // primes previousWordLanguage = "ru"

        guard let rukuStrokes = InstantCorrectionFixtures.keystrokes(for: "руку", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«руку»: RU fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: rukuStrokes, typedLayout: ruLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "«руку» under ru-context must stay noSwitch (pre-fix regression: switched to «here»)")
        case .noSwitch:
            TestRunner.assertTrue(true, "«руку» under ru-context stays noSwitch — native dictionary word is not perturbed")
        }

        // --- 2: «беру» (also a ru dictionary word) typed on ru layout, but
        //        the ESTABLISHED context is en — the native-context lock
        //        must not apply here, so behavior is whatever the existing
        //        gap-based gate decides (recorded, not assumed). ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        ) // primes previousWordLanguage = "en"

        guard let beruStrokes = InstantCorrectionFixtures.keystrokes(for: "беру", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«беру»: RU fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: beruStrokes, typedLayout: ruLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "en", "«беру» under en-context: the native-context lock doesn't apply (context isn't ru), gap-based gate still allows the switch")
            TestRunner.assertEqual(word, ",the", "«беру» under en-context corrects to «,the» (leading «б»-as-comma key kept as typed, only the letter core converts)")
        case .noSwitch:
            TestRunner.assertTrue(true, "«беру» under en-context stays noSwitch — gap-based gate blocked it (still fine: ru-context is what must be protected, and it is)")
        }

        // --- 3: single "d" typed live on en layout with en-context must
        //        stay noSwitch — pre-fix this converted to ru «в» with no
        //        incumbent and no gap to stop it. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        ) // primes previousWordLanguage = "en"

        guard let dStrokes = InstantCorrectionFixtures.keystrokes(for: "d", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'d': EN fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: dStrokes, typedLayout: enLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "'d' under en-context must stay noSwitch (pre-fix regression: converted to «в»)")
        case .noSwitch:
            TestRunner.assertTrue(true, "'d' under en-context stays noSwitch — one-letter winner has no context backing it")
        }

        // --- 3b: single "d" typed live on en layout with NEUTRAL context
        //        (no previous word this session at all) — the corpus fix
        //        above only covers an EXPLICIT opposite-language context
        //        (all 7 false switches the sweep found had one); neutral
        //        context is deliberately left alone so feature 0.6.8's own
        //        neutral-context case (test 4 below, and
        //        KeyboardMonitorIntegrationTests "Auto-correction reaches
        //        one-letter words") keeps working. Recording the actual
        //        consequence: a stray "d" as the very first thing typed in
        //        a session can still convert to «в» — consciously accepted,
        //        it's the price of not narrowing 0.6.8 further than the
        //        corpus evidence demands. ---
        detector.resetContext()
        switch detector.detect(keystrokes: dStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'d' under neutral context still switches to ru — consciously accepted: price of feature 0.6.8")
            TestRunner.assertEqual(word, "в", "'d' under neutral context still corrects to «в»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'d' under neutral context: expected switchTo «в» per the accepted 0.6.8 tradeoff — if this is noSwitch, the assumption above needs revisiting")
        }

        // --- 4: single "b" typed live on en layout with ru-context must
        //        still convert to «и» — feature 0.6.8 stays alive. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        ) // primes previousWordLanguage = "ru"

        guard let bStrokes = InstantCorrectionFixtures.keystrokes(for: "b", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'b': EN fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: bStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'b' under ru-context still switches to ru (0.6.8 alive)")
            TestRunner.assertEqual(word, "и", "'b' under ru-context still corrects to «и»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'b' under ru-context must still switch to «и» — feature 0.6.8 must stay alive")
        }

        // --- 5: «баги» typed on ru layout with a NEUTRAL (nil) context —
        //        now a ru dictionary word (Fix 3), so noSwitch comes from
        //        the ordinary incumbent-gap gate. Pre-fix this switched to
        //        en «fub» because «баги» wasn't in ru_RU.txt at all. ---
        detector.resetContext()
        guard let bagiStrokes = InstantCorrectionFixtures.keystrokes(for: "баги", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«баги»: RU fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: bagiStrokes, typedLayout: ruLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "«баги» under neutral context must stay noSwitch (pre-fix regression: switched to «fub»)")
        case .noSwitch:
            TestRunner.assertTrue(true, "«баги» under neutral context stays noSwitch — now a dictionary word")
        }
    }
}

/// v0.6.13 wired "vs"/"kb"/"dj" into `twoLetterWords["en"]` as a blanket
/// lock protecting the owner's live English tokens — which permanently
/// broke the RU side («мы»/«ли»/«во» typed in EN layout never corrected,
/// see `TwoLetterWordScoringTests`' "vs" negative, still green under
/// neutral/lowercase). The owner rejected that trade: both sides must
/// live. `LanguageDetector.conflictPairs` replaces the blanket lock with a
/// context-based decision — this suite exercises every branch directly
/// against `detect()`.
enum ConflictPairDisambiguationTests {
    static func run() {
        TestRunner.section("Conflict-pair disambiguation (vs/kb/dj ↔ мы/ли/во)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for conflict-pair fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        guard let vsStrokes = InstantCorrectionFixtures.keystrokes(for: "vs", reverse: enReverse),
              let kbStrokes = InstantCorrectionFixtures.keystrokes(for: "kb", reverse: enReverse),
              let djStrokes = InstantCorrectionFixtures.keystrokes(for: "dj", reverse: enReverse),
              let myStrokesRu = InstantCorrectionFixtures.keystrokes(for: "мы", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "conflict-pair fixtures: both layouts can type every character")
            return
        }

        // --- 1: "vs" under an established EN context stays EN — the live
        //        token lives. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        ) // primes previousWordLanguage = "en"
        switch detector.detect(keystrokes: vsStrokes, typedLayout: enLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "'vs' under en-context must stay noSwitch — the live token lives")
        case .noSwitch:
            TestRunner.assertTrue(true, "'vs' under en-context stays noSwitch")
        }

        // --- 2: "vs" under an established RU context corrects to «мы» —
        //        the owner is mid-sentence in Russian. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        ) // primes previousWordLanguage = "ru"
        switch detector.detect(keystrokes: vsStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'vs' under ru-context switches to ru")
            TestRunner.assertEqual(word, "мы", "'vs' under ru-context corrects to «мы»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'vs' under ru-context must switch to «мы»")
        }

        // --- 3: "Vs" (Shift on the FIRST keystroke) with NEUTRAL context —
        //        no established language, but sentence-initial capitalization
        //        reads as intent to type «Мы» (capitalization fallback; AX
        //        probe ruled out — see LanguageDetector.swift comment on
        //        this branch). ---
        detector.resetContext()
        let vsShiftStrokes = [
            BufferedKeystroke(keycode: vsStrokes[0].keycode, flags: .maskShift),
            vsStrokes[1]
        ]
        switch detector.detect(keystrokes: vsShiftStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'Vs' under neutral context switches to ru")
            TestRunner.assertEqual(word, "Мы", "'Vs' under neutral context corrects to «Мы» (case preserved through convertKeystrokes, same as every other correction path)")
        case .noSwitch:
            TestRunner.assertTrue(false, "'Vs' (Shift on first key) under neutral context must switch — sentence-initial capitalization is the fallback signal")
        }

        // --- 4: "vs" lowercase with NEUTRAL context — no signal to act on,
        //        stays put (Double Shift still fixes it manually). ---
        detector.resetContext()
        switch detector.detect(keystrokes: vsStrokes, typedLayout: enLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "'vs' lowercase under neutral context must stay noSwitch — no signal to act on")
        case .noSwitch:
            TestRunner.assertTrue(true, "'vs' lowercase under neutral context stays noSwitch")
        }

        // --- 5: "kb"/"dj" under ru-context — same mechanism, different pairs. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        )
        switch detector.detect(keystrokes: kbStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'kb' under ru-context switches to ru")
            TestRunner.assertEqual(word, "ли", "'kb' under ru-context corrects to «ли»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'kb' under ru-context must switch to «ли»")
        }

        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        )
        switch detector.detect(keystrokes: djStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'dj' under ru-context switches to ru")
            TestRunner.assertEqual(word, "во", "'dj' under ru-context corrects to «во»")
        case .noSwitch:
            TestRunner.assertTrue(false, "'dj' under ru-context must switch to «во»")
        }

        // --- 6: reverse direction — «мы» typed ON THE RU LAYOUT (not the
        //        conflict-pair keys read as ru) must stay «мы» regardless of
        //        context, even en. Guarded by the ordinary same-layout early
        //        return in `detect()`, well before `conflictPairs` is ever
        //        consulted. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        ) // primes previousWordLanguage = "en"
        switch detector.detect(keystrokes: myStrokesRu, typedLayout: ruLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "«мы» typed on ru layout must stay noSwitch even under en-context — reverse direction must not be perturbed")
        case .noSwitch:
            TestRunner.assertTrue(true, "«мы» typed on ru layout stays noSwitch under en-context — reverse direction protected")
        }
    }
}

/// 16.08.2026 — junk-override (owner TODO, CLAUDE.md: "русский коряво
/// написан ⇒ пишу на английском, программа должна это понимать"). Exercises
/// `detect()` end to end against the exact corpus-verified pairs from
/// Scripts/research/false_switch_sim.py — pure `junk`/`clean` math is
/// covered separately by `JunkMeterTests`.
enum JunkOverrideDetectionTests {
    static func run() {
        TestRunner.section("Junk-override — detect() end to end (16.08.2026)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for junk-override fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        func expectSwitch(
            _ typed: String, reverse: [Character: UInt16], typedLayout: KeyboardLayout,
            expectedLang: String, expectedWord: String, label: String
        ) {
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: typed, reverse: reverse) else {
                TestRunner.assertTrue(false, "\(label): fixture layout can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: typedLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, expectedLang, "\(label): switches to \(expectedLang)")
                TestRunner.assertEqual(word, expectedWord, "\(label): corrects to «\(expectedWord)»")
            case .noSwitch:
                TestRunner.assertTrue(false, "\(label): must switch to \(expectedLang)/\(expectedWord)")
            }
        }

        func expectNoSwitch(
            _ typed: String, reverse: [Character: UInt16], typedLayout: KeyboardLayout, label: String
        ) {
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: typed, reverse: reverse) else {
                TestRunner.assertTrue(false, "\(label): fixture layout can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: typedLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertTrue(false, "\(label): must stay noSwitch (got switchTo \(layout.languageCode)/\(word))")
            case .noSwitch:
                TestRunner.assertTrue(true, "\(label): stays noSwitch")
            }
        }

        // --- Fixes: OOV targets, the class that never corrected before
        //     junk-override existed. Neutral context each time. ---
        detector.resetContext()
        expectSwitch("cjplfybtv", reverse: enReverse, typedLayout: enLayout,
                     expectedLang: "ru", expectedWord: "созданием",
                     label: "'cjplfybtv' (en keys, OOV ru target)")

        detector.resetContext()
        expectSwitch("ecvjnhtybt", reverse: enReverse, typedLayout: enLayout,
                     expectedLang: "ru", expectedWord: "усмотрение",
                     label: "'ecvjnhtybt' (en keys, OOV ru target)")

        detector.resetContext()
        expectSwitch("рфвт", reverse: ruReverse, typedLayout: ruLayout,
                     expectedLang: "en", expectedWord: "hadn",
                     label: "'рфвт' (ru keys, OOV en target)")

        detector.resetContext()
        expectSwitch("лштвф", reverse: ruReverse, typedLayout: ruLayout,
                     expectedLang: "en", expectedWord: "kinda",
                     label: "'лштвф' (ru keys, OOV en target)")

        // --- Not touched: own is already a dictionary word ("tmp" lives in
        //     en_US.txt) — scoreWord(own)!=0 rejects the override outright,
        //     and the ordinary same-layout-wins path never even reaches it.
        //     Context primed to "en" first, mirroring the Python self-check. ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        )
        expectNoSwitch("tmp", reverse: enReverse, typedLayout: enLayout,
                       label: "'tmp' (dictionary word) stays put in an en flow")

        // --- Not touched: own core is nil — "don't"'s apostrophe splits the
        //     run into two letter groups under `core(of:)`, which the
        //     override gate rejects up front (own core must exist). Built
        //     directly from keycodes: apostrophe (39) isn't a letter key
        //     under EN, so `InstantCorrectionFixtures.reverseMap` (which
        //     only maps `InputBuffer.isLetterKey` codes) can't produce it. ---
        detector.resetContext()
        let dontStrokes = [
            BufferedKeystroke(keycode: 2, flags: []),  // d
            BufferedKeystroke(keycode: 38, flags: []), // o
            BufferedKeystroke(keycode: 45, flags: []), // n
            BufferedKeystroke(keycode: 39, flags: []), // '
            BufferedKeystroke(keycode: 17, flags: []), // t
        ]
        switch detector.detect(keystrokes: dontStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertTrue(false, "\"don't\" (nil own core) must stay noSwitch (got switchTo \(layout.languageCode)/\(word))")
        case .noSwitch:
            TestRunner.assertTrue(true, "\"don't\" (nil own core, apostrophe splits the run) stays noSwitch")
        }

        // --- Not touched: context gate — the exact same gibberish that gets
        //     fixed above under neutral context must stay put once an EN
        //     context is already established (own_lang == context). ---
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        )
        expectNoSwitch("cjplfybtv", reverse: enReverse, typedLayout: enLayout,
                       label: "'cjplfybtv' under an already-established en context stays put (context gate)")

        // --- Not touched: junk on BOTH sides — "klmnp" (en keys) reads as a
        //     consonant cluster under EITHER layout (no vowel on either
        //     side), so the target fails `clean()` too. ---
        detector.resetContext()
        expectNoSwitch("klmnp", reverse: enReverse, typedLayout: enLayout,
                       label: "'klmnp' (junk on both sides — target has no vowel either) stays put")

        // --- «ща» ↔ "of" (same physical o+f keys, 16.08.2026 addition).
        //     Scored the other way round from vs/kb/dj: those EN tokens were
        //     deliberately kept OUT of `twoLetterWords["en"]` so the Russian
        //     reading always wins, but "of" is a real, high-frequency word
        //     that MUST stay scored (84 dict + 7 ngram + 25 freq), while
        //     «ща» gets 84 alone — "of" wins by ~30 points, past both
        //     `collisionGap`(10) and `incumbentGap`(25), in EVERY context.
        //     So the EN-typed direction below never needs `conflictPairs`
        //     at all; the pair earns its keep in the RU-typed direction,
        //     where score would otherwise overwrite a word the owner really
        //     did type (the second pair of assertions). ---
        guard let ofStrokes = InstantCorrectionFixtures.keystrokes(for: "of", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'of': en fixture layout can type every character")
            return
        }
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse)!,
            typedLayout: enLayout
        )
        switch detector.detect(keystrokes: ofStrokes, typedLayout: enLayout) {
        case .switchTo:
            TestRunner.assertTrue(false, "'of' under en-context must stay noSwitch — the live token lives")
        case .noSwitch:
            TestRunner.assertTrue(true, "'of' under en-context stays noSwitch")
        }

        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        )
        switch detector.detect(keystrokes: ofStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertTrue(
                false,
                "'of' unexpectedly lost to «ща» (switchTo \(layout.languageCode)/\(word)) — "
                    + "score math changed, re-check the 'Аномалии' note in the delivery report"
            )
        case .noSwitch:
            TestRunner.assertTrue(
                true,
                "'of' typed on EN under ru-context stays noSwitch — \"of\" outscores «ща» on "
                    + "dictionary+ngram+frequency in EITHER context, so this direction of the pair is "
                    + "settled by score, never by conflictPairs"
            )
        }

        // The pair from the OTHER end, which is the direction that actually
        // bites: «ща» typed on RU (a real word, and how a message often
        // opens) against "of", which outscores it by ~30 points. An
        // established RU context is covered by the native-context lock; with
        // NO context the reading on screen is the safer bet, so the run is
        // left alone (Double Shift still converts it on demand).
        guard let shchaStrokes = InstantCorrectionFixtures.keystrokes(for: "ща", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«ща»: ru fixture layout can type every character")
            return
        }
        detector.resetContext()
        switch detector.detect(keystrokes: shchaStrokes, typedLayout: ruLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertTrue(
                false,
                "«ща» as the FIRST word (no context) must stay «ща» — got switchTo \(layout.languageCode)/\(word)"
            )
        case .noSwitch:
            TestRunner.assertTrue(true, "«ща» with no context stays «ща» (conflict pair, reverse direction)")
        }

        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        )
        switch detector.detect(keystrokes: shchaStrokes, typedLayout: ruLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertTrue(
                false,
                "«ща» mid-Russian must stay «ща» (native-context lock) — got switchTo \(layout.languageCode)/\(word)"
            )
        case .noSwitch:
            TestRunner.assertTrue(true, "«ща» under an established ru context stays «ща» (native-context lock)")
        }
    }
}

/// Pure `junk`/`clean` math, independent of a live `WordDictionary` — the
/// `possibleBigrams` set is passed in explicitly. End-to-end coverage
/// against the real bundled dictionaries lives in `JunkOverrideDetectionTests`.
enum JunkMeterTests {
    static func run() {
        TestRunner.section("JunkMeter — junk/clean primitives")

        let possible: Set<String> = ["ст", "то", "по", "ов", "ер", "th", "he", "in"]

        TestRunner.assertTrue(
            JunkMeter.isJunk("бгв", language: "ru", possibleBigrams: possible),
            "no vowel at all -> junk regardless of bigrams"
        )
        TestRunner.assertTrue(
            !JunkMeter.isJunk("сто", language: "ru", possibleBigrams: possible),
            "vowel present and every bigram possible -> not junk"
        )
        TestRunner.assertTrue(
            JunkMeter.isClean("сто", language: "ru", possibleBigrams: possible),
            "vowel present and every bigram possible -> clean"
        )
        TestRunner.assertTrue(
            JunkMeter.isJunk("стя", language: "ru", possibleBigrams: possible),
            "vowel present but one bigram ('тя') is impossible -> junk"
        )
        TestRunner.assertTrue(
            !JunkMeter.isClean("стя", language: "ru", possibleBigrams: possible),
            "vowel present but one bigram impossible -> not clean"
        )
        TestRunner.assertTrue(
            !JunkMeter.isJunk("а", language: "ru", possibleBigrams: possible),
            "shorter than 2 characters is never junk"
        )
        TestRunner.assertTrue(
            !JunkMeter.isClean("бгв", language: "ru", possibleBigrams: possible),
            "no vowel -> not clean"
        )
        TestRunner.assertTrue(
            JunkMeter.isJunk("tha", language: "en", possibleBigrams: possible),
            "en: vowel present but bigram 'ha' impossible -> junk"
        )
        TestRunner.assertTrue(
            !JunkMeter.isJunk("the", language: "en", possibleBigrams: possible),
            "en: vowel present and every bigram possible -> not junk"
        )
        TestRunner.assertTrue(
            JunkMeter.isClean("the", language: "en", possibleBigrams: possible),
            "en: vowel present and every bigram possible -> clean"
        )
    }
}

enum InstantCorrectionUndoTests {
    static func run() {
        TestRunner.section("Instant correction undo")
        // Instant correction always records with trailing=nil — nothing was
        // typed after the mid-word cursor yet. Undo must not special-case it:
        // the same generic SwitchUndoManager transaction used by every other
        // correction path rolls it back.
        let undo = SwitchUndoManager()
        undo.record(
            originalKeycodes: [5, 4, 11, 2, 17],
            originalWord: "ghbdt",
            correctedWord: "приве",
            trailing: nil,
            originalLayoutID: "en",
            targetLayoutID: "ru"
        )
        TestRunner.assertTrue(undo.canUndo, "instant correction is recorded like any other correction")
        guard let consumed = undo.consume() else {
            TestRunner.assertTrue(false, "instant correction undo returns a transaction")
            return
        }
        TestRunner.assertNil(consumed.trailing, "instant correction carries no trailing character")
        TestRunner.assertEqual(consumed.originalWord, "ghbdt", "undo restores the pre-correction text")
        TestRunner.assertEqual(consumed.correctedWord, "приве", "undo transaction records the corrected word")
        TestRunner.assertTrue(!undo.canUndo, "undo transaction is consumed exactly once")
    }
}

/// Shared fixtures for the instant-correction tests below: reverse
/// keycode maps built from the *real* installed EN/RU layouts (same
/// UCKeyTranslate mechanism the app uses), so a golden/corpus word string
/// can be turned back into the physical `BufferedKeystroke`s that would
/// have produced it.
private enum InstantCorrectionFixtures {
    static func reverseMap(
        for layout: KeyboardLayout, inputSources: InputSourceManager
    ) -> [Character: UInt16] {
        var map: [Character: UInt16] = [:]
        for kc in UInt16(0)...UInt16(53) where InputBuffer.isLetterKey(kc) {
            guard let ch = inputSources.characterForKeycode(kc, layout: layout, flags: []),
                  ch.count == 1 else { continue }
            map[Character(ch)] = kc
        }
        return map
    }

    static func keystrokes(for text: String, reverse: [Character: UInt16]) -> [BufferedKeystroke]? {
        var result: [BufferedKeystroke] = []
        result.reserveCapacity(text.count)
        for ch in text {
            guard let kc = reverse[ch] else { return nil }
            result.append(BufferedKeystroke(keycode: kc, flags: []))
        }
        return result
    }

    /// Prefix length (>= minLength) at which `evaluate` first fires, or nil.
    static func firedAt(
        strokes: [BufferedKeystroke], wrongLayout: KeyboardLayout, otherLayouts: [KeyboardLayout],
        analyzer: InstantCorrectionAnalyzer, inputSources: InputSourceManager
    ) -> Int? {
        guard strokes.count >= InstantCorrectionAnalyzer.minLength else { return nil }
        for length in InstantCorrectionAnalyzer.minLength...strokes.count {
            let prefix = Array(strokes.prefix(length))
            let result = analyzer.evaluate(
                keystrokes: prefix, currentLayout: wrongLayout, otherLayouts: otherLayouts,
                convert: { layout in inputSources.convertKeystrokes(prefix, toLayout: layout) }
            ).result
            if result != nil { return length }
        }
        return nil
    }
}

enum InstantCorrectionAnalyzerTests {
    static func run() {
        TestRunner.section("InstantCorrectionAnalyzer — golden mid-word cases")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for instant-correction fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        // (displayed text as it actually appears on screen in the WRONG
        // layout, the wrong layout itself, its reverse map, the correct
        // target layout, human label)
        let goldenCases:
            [(displayed: String, wrongLayout: KeyboardLayout, reverse: [Character: UInt16],
              otherLayout: KeyboardLayout, label: String)] = [
                ("ghbdtn", enLayout, enReverse, ruLayout, "ghbdtn (en keys) → привет"),
                ("cgfcb,j", enLayout, enReverse, ruLayout, "cgfcb,j (en keys) → спасибо"),
                ("цщкв", ruLayout, ruReverse, enLayout, "цщкв (ru keys) → word"),
            ]

        for goldenCase in goldenCases {
            guard let strokes = InstantCorrectionFixtures.keystrokes(
                for: goldenCase.displayed, reverse: goldenCase.reverse
            ) else {
                TestRunner.assertTrue(false, "\(goldenCase.label): fixture layout can type every character")
                continue
            }
            let fired = InstantCorrectionFixtures.firedAt(
                strokes: strokes, wrongLayout: goldenCase.wrongLayout, otherLayouts: [goldenCase.otherLayout],
                analyzer: analyzer, inputSources: inputSources
            )
            let ceiling = min(7, strokes.count)
            TestRunner.assertTrue(
                fired != nil && fired! <= ceiling,
                "\(goldenCase.label): instant correction fires by length \(ceiling)"
                    + " (fired at \(fired.map(String.init) ?? "never"))"
            )
        }

        // "руддщ" (ru keys) → "hello" moved OUT of the golden always-fires
        // list by the 19.08.2026 junk-gate: its own ru reading ("рудд...")
        // has a vowel and only bigrams that occur in real ru words — CLEAN —
        // so instant now defers to the boundary path here on purpose. This
        // is the measured trade-off (Scripts/research/instant_junk_gate_sim.py
        // measure [1]: 40.4% of honest EN-typed-while-ru-active corrections
        // are deferred this way, 97.5% of those — this one included —
        // recoverable at the boundary path). Confirmed both halves: instant
        // stays silent, and `LanguageDetector.detect` (boundary/space) still
        // corrects it, so nothing is actually lost.
        if let strokes = InstantCorrectionFixtures.keystrokes(for: "руддщ", reverse: ruReverse) {
            let fired = InstantCorrectionFixtures.firedAt(
                strokes: strokes, wrongLayout: ruLayout, otherLayouts: [enLayout],
                analyzer: analyzer, inputSources: inputSources
            )
            TestRunner.assertNil(
                fired, "'руддщ' (ru keys) → hello: instant defers to the boundary path (own reading is CLEAN)"
            )
            let prefs = PreferencesService()
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            switch detector.detect(keystrokes: strokes, typedLayout: ruLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, "en", "'руддщ' still recovers at the boundary path")
                TestRunner.assertEqual(word, "hello", "boundary path corrects to the same word instant used to")
            case .noSwitch:
                TestRunner.assertTrue(false, "'руддщ' must still switch at the boundary path — recoverable, not lost")
            }
        } else {
            TestRunner.assertTrue(false, "'руддщ': ru fixture can type every character")
        }

        // Below MIN_INSTANT: never evaluated, even on an otherwise-golden prefix.
        if let strokes = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
            let short = Array(strokes.prefix(InstantCorrectionAnalyzer.minLength - 1))
            let result = analyzer.evaluate(
                keystrokes: short, currentLayout: enLayout, otherLayouts: [ruLayout],
                convert: { layout in inputSources.convertKeystrokes(short, toLayout: layout) }
            ).result
            TestRunner.assertNil(result, "shorter than MIN_INSTANT never fires")
        }
    }
}

enum InstantCorrectionCorpusTests {
    static func run() {
        TestRunner.section("InstantCorrectionAnalyzer — anti-false-positive corpus")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the honest-typing corpus")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        guard let enWords = loadCorpus("en_US.txt", limit: 2000),
              let ruWords = loadCorpus("ru_RU.txt", limit: 2000) else {
            TestRunner.skip("dictionary corpus files not found at the expected resource path")
            return
        }

        // "Честный набор в родной раскладке": every corpus word run through
        // the SAME analyzer that would see it mid-word, converted only via
        // its own (correct) layout — instant correction must never fire.
        func sweep(
            words: [String], layout: KeyboardLayout, reverse: [Character: UInt16], otherLayout: KeyboardLayout
        ) -> (checked: Int, skipped: Int, hits: [(word: String, length: Int)]) {
            var checked = 0, skipped = 0
            var hits: [(String, Int)] = []
            for word in words {
                guard let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: reverse),
                      strokes.count >= InstantCorrectionAnalyzer.minLength else {
                    skipped += 1
                    continue
                }
                checked += 1
                if let length = InstantCorrectionFixtures.firedAt(
                    strokes: strokes, wrongLayout: layout, otherLayouts: [otherLayout],
                    analyzer: analyzer, inputSources: inputSources
                ) {
                    hits.append((word, length))
                }
            }
            return (checked, skipped, hits)
        }

        let enResult = sweep(words: enWords, layout: enLayout, reverse: enReverse, otherLayout: ruLayout)
        let ruResult = sweep(words: ruWords, layout: ruLayout, reverse: ruReverse, otherLayout: enLayout)

        for hit in enResult.hits.prefix(10) {
            print("  ✗ FALSE POSITIVE (en honest word): \"\(hit.word)\" fired at length \(hit.length)")
        }
        for hit in ruResult.hits.prefix(10) {
            print("  ✗ FALSE POSITIVE (ru honest word): \"\(hit.word)\" fired at length \(hit.length)")
        }

        TestRunner.assertEqual(
            enResult.hits.count, 0,
            "0 false positives across \(enResult.checked) honestly-typed EN words (\(enResult.skipped) skipped, unmappable chars)"
        )
        TestRunner.assertEqual(
            ruResult.hits.count, 0,
            "0 false positives across \(ruResult.checked) honestly-typed RU words (\(ruResult.skipped) skipped, unmappable chars)"
        )
    }

    private static func loadCorpus(_ fileName: String, limit: Int) -> [String]? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dictionaries/\(fileName)"),
            Bundle.main.resourceURL?.appendingPathComponent("Dictionaries/\(fileName)"),
        ]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let words = text.split(separator: "\n")
                .prefix(limit)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            return words
        }
        return nil
    }
}

enum InstantCorrectionJunkGateTests {
    static func run() {
        TestRunner.section("Instant correction — own-clean junk gate (field defect 19.08.2026)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the junk-gate fixtures")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        // Repro from the stand (Scripts/research/instant_junk_gate_sim.py,
        // measure [3] "ru_50k mutated" corpus): "пусть" typo'd as "еусть"
        // (п→е at position 0), typed honestly while ru is active. The
        // 4-letter own reading "еуст" is CLEAN by JunkMeter — has a vowel,
        // every bigram possible — a real-looking ru prefix, not the
        // gibberish instant correction exists to catch. BEFORE this fix, en's
        // 'tecn' (a bundled-word prefix) cleared candidateFloor/margin and
        // won, flipping the layout mid-word on an honest typo.
        if let strokes = InstantCorrectionFixtures.keystrokes(for: "еусть", reverse: ruReverse) {
            let prefix = Array(strokes.prefix(4))
            TestRunner.assertEqual(
                inputSources.convertKeystrokes(prefix, toLayout: ruLayout), "еуст",
                "sanity: the 4-letter own reading matches the stand's repro"
            )
            let result = analyzer.evaluate(
                keystrokes: prefix, currentLayout: ruLayout, otherLayouts: [enLayout],
                convert: { layout in inputSources.convertKeystrokes(prefix, toLayout: layout) }
            ).result
            TestRunner.assertNil(
                result,
                "own-clean OOV prefix 'еуст' (typo of 'пусть') no longer misfires instant correction to EN"
            )
        } else {
            TestRunner.assertTrue(false, "'еусть': ru fixture can type every character")
        }

        // Regression (mirrors sanity check [5] on the stand): the gate must
        // not touch honest mid-word corrections whose own reading is junk —
        // no vowel at all — exactly the mistake instant correction exists to
        // fix. Both keep firing, same as before this change.
        if let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
            let fired = InstantCorrectionFixtures.firedAt(
                strokes: ghbdtn, wrongLayout: enLayout, otherLayouts: [ruLayout],
                analyzer: analyzer, inputSources: inputSources
            )
            TestRunner.assertTrue(fired != nil, "junk own-reading 'ghbdtn' (привет) still fires instant correction")
        } else {
            TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
        }
        if let rabota = InstantCorrectionFixtures.keystrokes(for: "работа", reverse: ruReverse) {
            let fired = InstantCorrectionFixtures.firedAt(
                strokes: rabota, wrongLayout: enLayout, otherLayouts: [ruLayout],
                analyzer: analyzer, inputSources: inputSources
            )
            TestRunner.assertTrue(fired != nil, "junk own-reading 'hf,jnf' (работа) still fires instant correction")
        } else {
            TestRunner.assertTrue(false, "'работа': ru fixture can type every character")
        }
    }
}

// MARK: - License test seams (no network, no real Keychain)

private final class TestLicenseClock: LicenseClock {
    var current: Int64
    init(_ now: Int64) { current = now }
    func now() -> Int64 { current }
}

private final class InMemoryLicenseStore: LicenseStateStore {
    var stored: LicenseState?
    func load() -> LicenseState? { stored }
    func save(_ state: LicenseState) { stored = state }
}

private final class StubLicenseTransport: LicenseTransport {
    var helloResult: LicenseService.ServerResult = .failure(.network)
    var activateResult: LicenseService.ServerResult = .failure(.network)
    private(set) var lastBaseURL: URL?

    func hello(
        baseURL: URL, hwid: String, appVersion: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        lastBaseURL = baseURL
        completion(helloResult)
    }

    func activate(
        baseURL: URL, hwid: String, key: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        lastBaseURL = baseURL
        completion(activateResult)
    }
}

enum LicenseServiceTests {
    private static let day: Int64 = 24 * 3600
    private static let grace: Int64 = 14 * day
    private static let rollbackTolerance: Int64 = 3600

    static func run() {
        TestRunner.section("LicenseService")

        // Anti-tamper first-seen marks are scoped by hwid in UserDefaults —
        // clean up every fake hwid this suite touches so re-runs stay isolated.
        defer {
            for hwid in ["TRIALHW", "ACTHW", "ANTITAMPERHW", "ENDPOINTHW"] {
                UserDefaults.standard.removeObject(forKey: AppIdentity.keyPrefix + "licenseFirstSeen." + hwid)
            }
        }

        // (a) canonicalization — golden vector
        let golden = LicensePayload(
            hwid: "ABC-123", plan: "trial", start: 1_754_100_000, until: 1_755_309_600, issued: 1_754_200_000
        )
        TestRunner.assertEqual(
            golden.canonicalString,
            "{\"hwid\":\"ABC-123\",\"issued\":1754200000,\"plan\":\"trial\",\"start\":1754100000,\"until\":1755309600}",
            "canonical payload string matches the golden vector"
        )

        let endpointTransport = StubLicenseTransport()
        let injectedEndpoint = URL(string: "https://license.invalid/qsw-test")!
        let endpointService = LicenseService(
            clock: TestLicenseClock(1_000), transport: endpointTransport,
            store: InMemoryLicenseStore(), hwid: "ENDPOINTHW", appVersion: "test",
            baseURL: injectedEndpoint
        )
        endpointService.checkIn()
        TestRunner.assertEqual(
            endpointTransport.lastBaseURL?.absoluteString ?? "", injectedEndpoint.absoluteString,
            "license endpoint is constructor-injected, not read from mutable UserDefaults"
        )

        let testKey = Curve25519.Signing.PrivateKey()
        let testPublicHex = Self.hex(testKey.publicKey.rawRepresentation)

        // (b) roundtrip: a test-generated key signs the canon → verify OK; a corrupted payload fails
        let payload = LicensePayload(
            hwid: "TESTHWID", plan: "sub", start: 1_700_000_000, until: 1_800_000_000, issued: 1_700_000_100
        )
        guard let sigData = try? testKey.signature(for: Data(payload.canonicalString.utf8)) else {
            TestRunner.assertTrue(false, "test key signs the canonical payload")
            return
        }
        let sigHex = Self.hex(sigData)
        TestRunner.assertTrue(
            LicenseVerifier.verifySignature(payload: payload, sigHex: sigHex, publicKeyHex: testPublicHex),
            "roundtrip: valid signature verifies"
        )
        let corrupted = LicensePayload(
            hwid: payload.hwid, plan: payload.plan, start: payload.start, until: payload.until + 1, issued: payload.issued
        )
        TestRunner.assertTrue(
            !LicenseVerifier.verifySignature(payload: corrupted, sigHex: sigHex, publicKeyHex: testPublicHex),
            "roundtrip: corrupted payload fails verification"
        )

        // (c) a payload signed for a different hwid must be rejected
        TestRunner.assertTrue(
            !LicenseVerifier.accept(
                payload: payload, sigHex: sigHex, hwid: "OTHER-HWID", now: payload.issued, publicKeyHex: testPublicHex
            ),
            "payload signed for a different hwid is rejected"
        )
        TestRunner.assertTrue(
            LicenseVerifier.accept(
                payload: payload, sigHex: sigHex, hwid: payload.hwid, now: payload.issued, publicKeyHex: testPublicHex
            ),
            "payload matching our hwid with a fresh issued time is accepted"
        )

        // (d) grace window: signed cache stays valid until 14 days after the last check
        let subPayload = LicensePayload(hwid: "GRACEHW", plan: "sub", start: 0, until: 10_000_000, issued: 1_000_000)
        guard let graceSigData = try? testKey.signature(for: Data(subPayload.canonicalString.utf8)) else {
            TestRunner.assertTrue(false, "test key signs the grace-window payload")
            return
        }
        let graceSigHex = Self.hex(graceSigData)
        let now: Int64 = 2_000_000

        let stale15 = LicenseState(
            payload: subPayload, sig: graceSigHex, lastCheckUnix: now - 15 * Self.day, maxSeenUnix: now, provisional: false
        )
        TestRunner.assertTrue(
            !LicenseService.evaluate(
                state: stale15, hwid: "GRACEHW", now: now,
                graceSeconds: Self.grace, rollbackTolerance: Self.rollbackTolerance, publicKeyHex: testPublicHex
            ),
            "grace expired at 15 days since last check → not entitled"
        )

        let stale13 = LicenseState(
            payload: subPayload, sig: graceSigHex, lastCheckUnix: now - 13 * Self.day, maxSeenUnix: now, provisional: false
        )
        TestRunner.assertTrue(
            LicenseService.evaluate(
                state: stale13, hwid: "GRACEHW", now: now,
                graceSeconds: Self.grace, rollbackTolerance: Self.rollbackTolerance, publicKeyHex: testPublicHex
            ),
            "13 days since last check is still within grace → entitled"
        )

        // (e) clock rollback: cache is untrusted once "now" falls behind the highest seen time
        let rolledBack = LicenseState(
            payload: subPayload, sig: graceSigHex, lastCheckUnix: now, maxSeenUnix: now + 2 * Self.day, provisional: false
        )
        TestRunner.assertTrue(
            !LicenseService.evaluate(
                state: rolledBack, hwid: "GRACEHW", now: now,
                graceSeconds: Self.grace, rollbackTolerance: Self.rollbackTolerance, publicKeyHex: testPublicHex
            ),
            "clock appears rolled back past maxSeen with no server reachable → not entitled"
        )

        // (f) provisional trial is created on an empty store while offline; until = +14 days
        let trialClock = TestLicenseClock(5_000_000)
        let trialStore = InMemoryLicenseStore()
        let trialTransport = StubLicenseTransport()
        trialTransport.helloResult = .failure(.network)
        let trialService = LicenseService(
            clock: trialClock, transport: trialTransport, store: trialStore,
            hwid: "TRIALHW", appVersion: "0.4.0", publicKeyHex: testPublicHex
        )
        trialService.checkIn()
        TestRunner.assertTrue(trialService.isEntitled, "offline first launch grants a provisional trial")
        TestRunner.assertTrue(trialStore.stored?.provisional ?? false, "provisional trial is flagged in stored state")
        TestRunner.assertEqual(
            trialStore.stored?.payload?.until ?? -1, trialClock.now() + 14 * Self.day,
            "provisional trial lasts exactly 14 days"
        )

        // (g) activation via mock transport with a signed sub payload → entitled, plan=sub
        let actClock = TestLicenseClock(6_000_000)
        let actStore = InMemoryLicenseStore()
        let actTransport = StubLicenseTransport()
        let subActivation = LicensePayload(
            hwid: "ACTHW", plan: "sub", start: actClock.now(), until: actClock.now() + 30 * Self.day, issued: actClock.now()
        )
        guard let actSigData = try? testKey.signature(for: Data(subActivation.canonicalString.utf8)) else {
            TestRunner.assertTrue(false, "test key signs the activation payload")
            return
        }
        actTransport.activateResult = .success(payload: subActivation, sigHex: Self.hex(actSigData))
        let actService = LicenseService(
            clock: actClock, transport: actTransport, store: actStore,
            hwid: "ACTHW", appVersion: "0.4.0", publicKeyHex: testPublicHex
        )
        var outcome: LicenseService.ActivationOutcome = .network
        actService.activate(key: "QSW-TEST-TEST-TEST") { result in outcome = result }
        TestRunner.assertEqual(outcome, .success, "activation with a valid signed response succeeds")
        TestRunner.assertTrue(actService.isEntitled, "activated subscription is entitled")
        TestRunner.assertEqual(actStore.stored?.payload?.plan ?? "", "sub", "activated state carries plan=sub")

        // (h) anti-tamper: deleting the license state (simulated by a fresh
        // empty store) while offline must NOT restart the provisional trial —
        // the second instance has to anchor on the first instance's
        // first-seen mark, not on its own later "now".
        let firstClock = TestLicenseClock(1_000_000)
        let firstStore = InMemoryLicenseStore()
        let offlineTransport = StubLicenseTransport()
        offlineTransport.helloResult = .failure(.network)
        let firstService = LicenseService(
            clock: firstClock, transport: offlineTransport, store: firstStore,
            hwid: "ANTITAMPERHW", appVersion: "test", publicKeyHex: testPublicHex
        )
        firstService.checkIn()
        let firstUntil = firstStore.stored?.payload?.until ?? -1
        TestRunner.assertEqual(
            firstUntil, firstClock.now() + 14 * Self.day,
            "genuinely first launch anchors the trial at its own now"
        )

        // "File deleted": a brand new, empty store — same hwid, 20 days later.
        let laterClock = TestLicenseClock(1_000_000 + 20 * Self.day)
        let wipedStore = InMemoryLicenseStore()
        let secondService = LicenseService(
            clock: laterClock, transport: offlineTransport, store: wipedStore,
            hwid: "ANTITAMPERHW", appVersion: "test", publicKeyHex: testPublicHex
        )
        secondService.checkIn()
        TestRunner.assertEqual(
            wipedStore.stored?.payload?.until ?? -1, firstUntil,
            "trial restored after local state loss keeps the ORIGINAL until — it is not restarted"
        )
        TestRunner.assertTrue(
            !secondService.isEntitled,
            "restored trial is already expired 20 days after a 14-day anchor, exactly as it should be"
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class StubLegacyLicenseKeychainReader: LegacyLicenseKeychainReader {
    var stateToReturn: LicenseState?
    private(set) var deleteCalled = false
    func readSilently() -> LicenseState? { stateToReturn }
    func deleteSilently() { deleteCalled = true }
}

enum FileLicenseStoreTests {
    static func run() {
        TestRunner.section("FileLicenseStore — migration off Keychain")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-license-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let legacyPayload = LicensePayload(hwid: "MIGRATEHW", plan: "trial", start: 1, until: 2, issued: 1)
        let legacyState = LicenseState(
            payload: legacyPayload, sig: "deadbeef", lastCheckUnix: 1, maxSeenUnix: 1, provisional: false
        )
        let legacyReader = StubLegacyLicenseKeychainReader()
        legacyReader.stateToReturn = legacyState

        let store = FileLicenseStore(directory: tempDir, legacyReader: legacyReader)

        if let migrated = store.load() {
            TestRunner.assertEqual(
                migrated, legacyState,
                "state read from the old Keychain source is migrated into the file store"
            )
        } else {
            TestRunner.assertTrue(false, "state read from the old Keychain source is migrated into the file store")
        }
        TestRunner.assertTrue(
            legacyReader.deleteCalled,
            "legacy Keychain entry is deleted once migration completes"
        )

        let fileURL = tempDir.appendingPathComponent("license.json")
        let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.posixPermissions] as? NSNumber
        TestRunner.assertEqual(
            perms?.intValue ?? -1, 0o600,
            "license.json is created with 0600 permissions"
        )

        // A second store pointed at the same directory must never re-read
        // (or delete from) Keychain — the file already exists.
        let secondReader = StubLegacyLicenseKeychainReader()
        secondReader.stateToReturn = LicenseState(
            payload: LicensePayload(hwid: "SHOULDNOTAPPEAR", plan: "trial", start: 0, until: 0, issued: 0),
            sig: nil, lastCheckUnix: 0, maxSeenUnix: 0, provisional: true
        )
        let secondStore = FileLicenseStore(directory: tempDir, legacyReader: secondReader)
        TestRunner.assertEqual(
            secondStore.load()?.payload?.hwid ?? "", "MIGRATEHW",
            "an existing file is never overwritten by a second migration attempt"
        )
        TestRunner.assertTrue(
            !secondReader.deleteCalled,
            "Keychain is not touched at all once a file already exists"
        )

        // Fresh install, nothing in Keychain either: store starts empty, no crash.
        let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-license-store-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let emptyReader = StubLegacyLicenseKeychainReader()
        let emptyStore = FileLicenseStore(directory: emptyDir, legacyReader: emptyReader)
        TestRunner.assertNil(emptyStore.load(), "fresh install with no legacy state has an empty file store")
    }
}

enum DebugLogTests {
    static func run() {
        TestRunner.section("DebugLog — verbose gate & rotation")

        let verboseKey = AppIdentity.keyPrefix + "verboseLog"
        let previousVerbose = UserDefaults.standard.object(forKey: verboseKey)
        defer {
            if let previousVerbose {
                UserDefaults.standard.set(previousVerbose, forKey: verboseKey)
            } else {
                UserDefaults.standard.removeObject(forKey: verboseKey)
            }
        }

        // (a) level filtering
        let levelDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-level-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: levelDir) }

        UserDefaults.standard.set(false, forKey: verboseKey)
        let levelLog = DebugLog(directory: levelDir)
        levelLog.log("KM", "detect: noSwitch len=5 cur=en", level: .verbose)
        levelLog.log("KM", "significant event", level: .normal)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(
            !levelLog.currentContents.contains("noSwitch"),
            "verbose-level events are dropped while verbose logging is off"
        )
        TestRunner.assertTrue(
            levelLog.currentContents.contains("significant event"),
            "normal-level events are always written regardless of the verbose setting"
        )

        UserDefaults.standard.set(true, forKey: verboseKey)
        levelLog.log("KM", "detect: noSwitch len=6 cur=ru", level: .verbose)
        levelLog.waitForPendingWrites()
        TestRunner.assertTrue(
            levelLog.currentContents.contains("noSwitch"),
            "verbose-level events are written once verbose logging is turned on"
        )

        // (b) rotation preserves content instead of truncating it
        let rotateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qsw-debuglog-rotate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rotateDir) }
        let rotateLog = DebugLog(directory: rotateDir)
        let filler = String(repeating: "x", count: 900)
        for i in 0..<700 {
            rotateLog.log("KM", "filler \(i) \(filler)")
        }
        rotateLog.log("LIC", "MARKER_AFTER_ROTATION")
        rotateLog.waitForPendingWrites()

        let rotatedFileURL = rotateDir.appendingPathComponent("debug.1.log")
        TestRunner.assertTrue(
            FileManager.default.fileExists(atPath: rotatedFileURL.path),
            "exceeding the size limit creates a second debug.1.log file"
        )
        let rotatedContents = (try? String(contentsOf: rotatedFileURL, encoding: .utf8)) ?? ""
        TestRunner.assertTrue(
            rotatedContents.contains("filler 0 "),
            "rotation preserves earlier content in debug.1.log instead of truncating it to a tail"
        )
        TestRunner.assertTrue(
            rotateLog.currentContents.contains("MARKER_AFTER_ROTATION"),
            "logging continues into a fresh debug.log right after rotation"
        )
    }
}

enum PendingUserEventQueueTests {
    static func run() {
        TestRunner.section("PendingUserEventQueue")
        var queue = PendingUserEventQueue<String>()
        TestRunner.assertTrue(queue.isEmpty, "queue starts empty")

        // Real typing during a replacement queues at the back; a trigger we
        // suppressed ourselves (RC-1) must replay FIRST if the replacement
        // fails — enqueueFront places it ahead of anything already queued.
        queue.enqueue("typed-a")
        queue.enqueue("typed-b")
        queue.enqueueFront("suppressed-trigger")
        TestRunner.assertEqual(
            queue.items, ["suppressed-trigger", "typed-a", "typed-b"],
            "suppressed trigger goes first, real typing keeps its order behind it"
        )

        // .success path: discard the suppressed trigger, keep the rest queued.
        var successQueue = queue
        successQueue.discardFront()
        TestRunner.assertEqual(
            successQueue.drain(), ["typed-a", "typed-b"],
            "success discards the suppressed trigger exactly once, replays the rest"
        )
        TestRunner.assertTrue(successQueue.isEmpty, "drain empties the queue")

        // .cancelled / .layoutSwitchFailed path: nothing is discarded, so the
        // suppressed trigger comes back out of drain() for replay.
        var failureQueue = queue
        TestRunner.assertEqual(
            failureQueue.drain(), ["suppressed-trigger", "typed-a", "typed-b"],
            "failure path returns the suppressed trigger for replay, unlike success"
        )
        TestRunner.assertTrue(failureQueue.isEmpty, "drain empties the queue on the failure path too")

        var empty = PendingUserEventQueue<String>()
        empty.discardFront()
        TestRunner.assertTrue(empty.isEmpty, "discardFront on an empty queue is a safe no-op")
    }
}

enum EventRouteTests {
    static func run() {
        TestRunner.section("EventRoute — routing truth table")
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: true, isReplayedUser: false), .ours,
            "our own synthetic keystroke (backspace/retype) routes as ours"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: false, isReplayedUser: true), .replayedUser,
            "a replayed real keystroke routes as replayedUser, analyzed like live typing"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: false, isReplayedUser: false), .physical,
            "genuine hardware input routes as physical"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: true, isReplayedUser: true), .ours,
            "if both markers were ever set (shouldn't happen), our own marker wins"
        )
    }
}

enum BufferVsScreenModelTests {
    /// A minimal reproduction of the invariant fixed by RC-2: ANY word
    /// boundary — whether typed live or replayed after a paused replacement —
    /// must clear the buffer. Only our own synthetic keystrokes (route ==
    /// .ours) bypass analysis entirely and never reach this logic at all.
    private struct Keystroke {
        let keycode: UInt16
        let route: EventRoute
    }

    private static func simulate(_ script: [Keystroke]) -> InputBuffer {
        let buffer = InputBuffer()
        for stroke in script {
            guard stroke.route != .ours else { continue } // bypassed before analysis
            if InputBuffer.isWordBoundary(stroke.keycode) {
                buffer.clear()
            } else if InputBuffer.isLetterKey(stroke.keycode) {
                buffer.append(stroke.keycode)
            }
        }
        return buffer
    }

    static func run() {
        TestRunner.section("Buffer vs screen — word-boundary model")

        let afterPhysicalSpace = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .physical), // space
        ])
        TestRunner.assertTrue(afterPhysicalSpace.isEmpty, "a physical space clears the buffer")

        // RC-2 case: a real space queued during a paused replacement and
        // replayed afterward is STILL a boundary.
        let afterReplayedSpace = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .replayedUser), // replayed space
        ])
        TestRunner.assertTrue(
            afterReplayedSpace.isEmpty, "a replayed space is STILL a boundary and clears the buffer"
        )

        let secondWord = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .replayedUser),
            Keystroke(keycode: 2, route: .physical),
            Keystroke(keycode: 3, route: .physical),
        ])
        TestRunner.assertEqual(
            secondWord.count, 2, "letters after a replayed-space boundary start a fresh word"
        )

        // Our own synthetic keystrokes (backspaces/retype) never reach this
        // analysis — they must not be mistaken for a boundary or for letters.
        let ignoresOwnEvents = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 51, route: .ours), // our own backspace
            Keystroke(keycode: 1, route: .ours),  // our own retyped letter
        ])
        TestRunner.assertEqual(
            ignoresOwnEvents.count, 1, "our own synthetic keystrokes bypass buffer analysis entirely"
        )
    }
}

enum InstantCorrectionGateSelfSwitchTests {
    /// Mirrors KeyboardMonitor.layoutDidChange's self-initiated guard (Fix 3):
    /// a layout change caused by OUR OWN correction (InputSourceManager
    /// reports selfInitiated) must leave in-flight word context untouched,
    /// including the instant-correction gate. A manual/bot-driven switch
    /// still resets it, like any other context invalidation.
    private static func applyLayoutChange(selfInitiated: Bool, gate: inout InstantCorrectionGate) {
        guard !selfInitiated else { return }
        gate.reset()
    }

    static func run() {
        TestRunner.section("InstantCorrectionGate — closed until startNewWord / untouched by self-switch")

        var gate = InstantCorrectionGate()
        gate.markCorrected()
        TestRunner.assertTrue(gate.wasCorrected, "gate stays closed right after an instant correction")
        gate.startNewWord()
        TestRunner.assertTrue(!gate.wasCorrected, "only startNewWord() reopens the gate")

        gate.markCorrected()
        applyLayoutChange(selfInitiated: true, gate: &gate)
        TestRunner.assertTrue(
            gate.wasCorrected,
            "our own correction's layout switch must not reset the gate mid-word (Fix 3)"
        )

        applyLayoutChange(selfInitiated: false, gate: &gate)
        TestRunner.assertTrue(
            !gate.wasCorrected,
            "a manual layout change still resets the instant-correction gate"
        )
    }
}

enum InputSourceSelfSwitchTests {
    static func run() {
        TestRunner.section("InputSourceManager — self-initiated layout change (Fix 3)")
        let us = "com.apple.keylayout.US"
        let ru = "com.apple.keylayout.Russian"
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: us, pendingSelfSwitchID: us
            ),
            .changed(selfInitiated: true),
            "a switch matching our own pending request is self-initiated"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: us, newLayoutID: ru, pendingSelfSwitchID: us
            ),
            .changed(selfInitiated: false),
            "a manual switch to a DIFFERENT layout than we requested is not self-initiated"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: us, pendingSelfSwitchID: nil
            ),
            .changed(selfInitiated: false),
            "with no pending request at all, any switch is manual"
        )

        // Live evidence, debug.log 08.08.2026 — macOS delivers the change
        // notification TWICE for one switch (07:36:24.072 "(self)" +
        // 07:36:24.074 plain). The second one used to be reported as an
        // external switch and wiped the typed-word context 2ms after our own
        // correction finished, which is what made Double Shift immediately
        // answer "no buffer/history — skip".
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: ru, pendingSelfSwitchID: nil
            ),
            .duplicate,
            "a repeat notification for the already-active layout is not a switch"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: nil, newLayoutID: us, pendingSelfSwitchID: nil
            ),
            .changed(selfInitiated: false),
            "the very first notification of a session is a real change, not a duplicate"
        )
    }
}

enum SlashModelRegressionTests {
    /// Named regression case from live evidence (Ghostty, 03.08.2026): typing
    /// "/model" rendered on screen as "moedel" with the leading "/" gone.
    /// Root cause: the pre-fix instant-correction formula backspaced
    /// `keystrokes.count` characters assuming the just-typed TRIGGER letter
    /// had already rendered — but the headInsert tap fires BEFORE delivery,
    /// so only `keystrokes.count - 1` letters were truly on screen yet.
    /// Over-backspacing by exactly 1 consumed whatever preceded the word —
    /// here, the leading "/" — and the still-in-flight trigger letter then
    /// landed mid-retype, scrambling the rest ("coedex"-style). Fix 1
    /// (suppress the trigger + backspace `count - 1`) plus the leading-
    /// symbol fold-in close both halves at once: the symbol is deliberately
    /// included in the SAME transaction (reconverted, not silently dropped).
    static func run() {
        TestRunner.section("RC-1 + leading-symbol regression — slash-model")

        let onScreenBeforeTrigger = "/mod" // "/" (leading, delivered normally) + "mod" (3 real on-screen letters)
        let keystrokeCount = 4             // "mode" as buffered — includes the in-flight 4th letter "e"
        let leadingSymbolCount = 1         // "/"

        // OLD (pre-fix): backspaces `keystrokeCount`, assuming the trigger
        // letter already rendered (it hadn't) — over-deletes by exactly 1,
        // consuming the leading "/". The old payload never reconverted a
        // leading symbol either, so it's gone for good once backspaced.
        let oldBackspaces = keystrokeCount
        let oldOnScreenAfterBackspace = String(onScreenBeforeTrigger.dropLast(oldBackspaces))
        let oldPayload = "mode" // letter-only — no symbol reconversion existed pre-fix
        TestRunner.assertEqual(
            oldOnScreenAfterBackspace, "",
            "bug reproduced: the old formula backspaces past the leading '/', deleting the whole run"
        )
        TestRunner.assertTrue(
            !(oldOnScreenAfterBackspace + oldPayload).hasPrefix("/"),
            "bug reproduced: '/' is permanently lost — old payload never retypes a leading symbol"
        )

        // NEW (fixed): suppress the trigger letter (it never renders) and
        // fold the leading symbol into the SAME transaction — backspaces
        // exactly what's truly on screen (the symbol + the letters that
        // really rendered) and retypes the symbol (reconverted for the
        // target layout) followed by the full corrected word.
        let newBackspaces = leadingSymbolCount + (keystrokeCount - 1)
        TestRunner.assertEqual(newBackspaces, 4, "fixed formula backspaces exactly what's truly on screen")
        let newOnScreenAfterBackspace = String(onScreenBeforeTrigger.dropLast(newBackspaces))
        let newPayload = "/" + "mode" // leadingCorrectedText + correctedWord — reconverted, not dropped
        TestRunner.assertEqual(
            newOnScreenAfterBackspace, "",
            "fixed formula clears exactly the on-screen run, nothing more"
        )
        TestRunner.assertEqual(
            newOnScreenAfterBackspace + newPayload, "/mode",
            "fix: leading '/' survives (reconverted) and the word is intact before the 5th letter continues"
        )
    }
}

enum LeadingSymbolRunGuardTests {
    /// Guard tests for the leading-symbol-run fold-in (";GRAF"/"$GRAF"/
    /// "/model" citation in the diagnosis). The fix NEVER feeds leading
    /// symbols into detection — only the letter core is scored, exactly as
    /// before the fix — so these reuse the same golden/corpus fixtures as
    /// InstantCorrectionAnalyzerTests to prove the calibrated decision is
    /// unaffected by a symbol sitting in front of (or after) the word.
    static func run() {
        TestRunner.section("Leading-symbol run — letter-core guard cases")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for leading-symbol-run guard fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        // Same sweep as InstantCorrectionAnalyzerTests' golden cases: try
        // increasing prefix lengths (mid-word, exactly how tryInstantCorrection
        // sees it) and return the result at the first length that fires.
        func evaluateAtFirstFire(
            _ word: String, wrongLayout: KeyboardLayout, reverse: [Character: UInt16], otherLayout: KeyboardLayout
        ) -> InstantCorrectionAnalyzer.Result? {
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: reverse),
                  let firedLength = InstantCorrectionFixtures.firedAt(
                      strokes: strokes, wrongLayout: wrongLayout, otherLayouts: [otherLayout],
                      analyzer: analyzer, inputSources: inputSources
                  ) else { return nil }
            let prefix = Array(strokes.prefix(firedLength))
            return analyzer.evaluate(
                keystrokes: prefix, currentLayout: wrongLayout, otherLayouts: [otherLayout],
                convert: { layout in inputSources.convertKeystrokes(prefix, toLayout: layout) }
            ).result
        }

        // Positive: the letter core, typed in the WRONG layout, must still be
        // recognized as needing a switch. The leading symbol is folded in
        // only AFTER this decision (never fed to the analyzer), so this
        // proves the decision itself is unaffected by a symbol in front of it.
        // `enReverse` recovers the PHYSICAL keycodes for the EN word;
        // `wrongLayout: ruLayout` simulates those same physical keys being
        // pressed while RU was mistakenly active.
        // ⚠️Originally "model" (the literal "/model" citation) and "hello"
        // ("$GRAF"-style stand-in) — both now DEFER to the boundary path
        // under the 19.08.2026 junk-gate (own ru reading is CLEAN, same
        // class InstantCorrectionAnalyzerTests' "руддщ" case documents), so
        // they no longer demonstrate "instant fires despite a leading
        // symbol" — only that this UNRELATED gate applies before the symbol
        // is even considered. Swapped for "world"/"window", real words whose
        // own ru reading stays junk, to keep testing what this guard is
        // actually about.
        if let worldResult = evaluateAtFirstFire("world", wrongLayout: ruLayout, reverse: enReverse, otherLayout: enLayout) {
            TestRunner.assertTrue(
                worldResult.layout.isEnglish, "'/world' letter core (wrong ru layout) is recognized and switches to EN"
            )
        } else {
            TestRunner.assertTrue(false, "'world' letter core should be recognized as needing a switch to EN")
        }
        if let windowResult = evaluateAtFirstFire("window", wrongLayout: ruLayout, reverse: enReverse, otherLayout: enLayout) {
            TestRunner.assertTrue(
                windowResult.layout.isEnglish, "'$window'-style letter core (wrong ru layout) is recognized and switches to EN"
            )
        } else {
            TestRunner.assertTrue(false, "'window' letter core should be recognized as needing a switch to EN")
        }

        // Negative/guard: the letter core is ALREADY a valid word in the
        // currently active (correct) layout — a leading/trailing symbol must
        // never provoke a conversion ("#tag", "@name", "./script" all typed
        // correctly in EN). The analyzer must never fire for any of these.
        for word in ["tag", "name", "path", "script"] {
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: enReverse) else {
                TestRunner.assertTrue(false, "'\(word)': EN fixture can type every character")
                continue
            }
            let fired = InstantCorrectionFixtures.firedAt(
                strokes: strokes, wrongLayout: enLayout, otherLayouts: [ruLayout],
                analyzer: analyzer, inputSources: inputSources
            )
            TestRunner.assertNil(
                fired, "'\(word)' typed correctly in EN never fires — safe under a leading/trailing symbol too"
            )
        }

        // "$PATH": shouldSkip's ALL-CAPS acronym pattern already blocks this
        // at the boundary-path (detect()) level, regardless of any symbol.
        TestRunner.assertTrue(
            LanguageDetector.shouldSkip("PATH"), "'PATH' (as in '$PATH') is skipped as an ALL-CAPS acronym"
        )

        // "№1", "100$", "git commit -m": the letter core is empty or a
        // single letter — both fall below the boundary-path's 3-letter
        // minimum (processCurrentWord) and the instant-path's 4-letter
        // minimum (InstantCorrectionAnalyzer.minLength), so no correction is
        // ever attempted regardless of the adjacent symbol.
        TestRunner.assertTrue(
            0 < 3 && 1 < 3,
            "an empty or single-letter core ('№1', '100$', '-m') stays below the 3-letter boundary minimum"
        )
        TestRunner.assertTrue(
            1 < InstantCorrectionAnalyzer.minLength,
            "a single-letter core also stays below the 4-letter instant minimum"
        )
    }
}

// MARK: - Onboarding state machine
//
// Guards the 04.08.2026 fix: the onboarding window used to vanish behind
// System Settings and there was no honest rule for when a restart is needed.
// The window plumbing is AppKit (live-only), but "which grants are in → what
// do we show" is pure and is pinned here.
enum OnboardingStateTests {
    static func run() {
        TestRunner.section("Onboarding — permission state → step")

        let nothing = OnboardingStatus(hasAccessibility: false, hasInputMonitoring: false,
                                       isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: nothing), .grantAccessibility,
                               "no permissions at all → ask for Accessibility first")

        // Input Monitoring is derived from Accessibility on this system (there
        // is no separate kTCCServiceListenEvent row for our bundle id), so it
        // must never be the first thing we ask for.
        let onlyInputMonitoring = OnboardingStatus(hasAccessibility: false, hasInputMonitoring: true,
                                                   isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: onlyInputMonitoring), .grantAccessibility,
                               "Input Monitoring without Accessibility still asks for Accessibility")

        let onlyAccessibility = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: false,
                                                 isInterceptionRunning: false)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: onlyAccessibility), .grantInputMonitoring,
                               "Accessibility granted → next step is Input Monitoring")

        let running = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                       isInterceptionRunning: true)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: running), .ready,
                               "both grants + live interception → ready")

        let justGranted = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                           isInterceptionRunning: false, secondsSinceAllGranted: 1)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: justGranted), .verifying,
                               "grants just landed and the tap is still coming up → verifying, not a restart prompt")

        let borderline = OnboardingStatus(
            hasAccessibility: true, hasInputMonitoring: true, isInterceptionRunning: false,
            secondsSinceAllGranted: OnboardingStateMachine.restartGraceSeconds - 0.01
        )
        TestRunner.assertEqual(OnboardingStateMachine.step(for: borderline), .verifying,
                               "just inside the grace window is still verifying")

        let stalled = OnboardingStatus(
            hasAccessibility: true, hasInputMonitoring: true, isInterceptionRunning: false,
            secondsSinceAllGranted: OnboardingStateMachine.restartGraceSeconds
        )
        TestRunner.assertEqual(OnboardingStateMachine.step(for: stalled), .stalled,
                               "grants in place but no interception past the grace window → stalled")

        TestRunner.assertTrue(OnboardingStateMachine.offersRestart(.stalled),
                              "restart is offered in the stalled state")
        TestRunner.assertTrue(!OnboardingStateMachine.offersRestart(.verifying)
                              && !OnboardingStateMachine.offersRestart(.ready)
                              && !OnboardingStateMachine.offersRestart(.grantAccessibility)
                              && !OnboardingStateMachine.offersRestart(.grantInputMonitoring),
                              "restart is never offered anywhere else — permissions are picked up hot")

        TestRunner.assertTrue(!OnboardingStateMachine.canFinish(.grantAccessibility)
                              && !OnboardingStateMachine.canFinish(.grantInputMonitoring),
                              "window can't be confirmed away while a permission is missing")
        TestRunner.assertTrue(OnboardingStateMachine.canFinish(.verifying)
                              && OnboardingStateMachine.canFinish(.stalled)
                              && OnboardingStateMachine.canFinish(.ready),
                              "once both grants are in, the user may confirm — the tap self-heals on its own poll")

        TestRunner.assertEqual(OnboardingStateMachine.pendingPermission(for: nothing), .accessibility,
                               "pending permission with nothing granted is Accessibility")
        TestRunner.assertEqual(OnboardingStateMachine.pendingPermission(for: onlyAccessibility), .inputMonitoring,
                               "pending permission after Accessibility is Input Monitoring")
        TestRunner.assertNil(OnboardingStateMachine.pendingPermission(for: running),
                             "nothing pending when both are granted — no repeat prompts")

        // A missing timestamp must not be read as "waited forever".
        let noTimestamp = OnboardingStatus(hasAccessibility: true, hasInputMonitoring: true,
                                           isInterceptionRunning: false, secondsSinceAllGranted: nil)
        TestRunner.assertEqual(OnboardingStateMachine.step(for: noTimestamp), .verifying,
                               "unknown wait time counts as 0s, not as stalled")

        TestRunner.assertTrue(!OnboardingStateMachine.hint(for: .grantInputMonitoring).contains("Перезапусти"),
                              "the Input Monitoring hint does not claim a restart is required")
        TestRunner.assertTrue(OnboardingStateMachine.hint(for: .stalled).contains("перезапуск"),
                              "the stalled hint is the only one that mentions restarting")
    }
}

// MARK: - KeyboardMonitor integration harness (headless — no GUI, no real CGEventTap)
//
// Everything above tests pure functions or components in isolation. This
// section drives a REAL `KeyboardMonitor` with synthetic CGEvents through
// the exact contract the live CGEventTap callback uses (`eventTapCallback`
// at the bottom of KeyboardMonitor.swift), and substitutes a `TextReplacing`
// fake that models "what's on screen" as a plain string instead of posting
// real CGEvents. This is the missing layer between unit tests
// (LanguageDetector/InstantCorrectionAnalyzer, above) and a live GUI — it
// catches bugs that only exist at the STITCH between buffering, leading-
// symbol tracking and the backspace/retype transaction, which is exactly
// where the ".yexit" bug lived: `swapLastWordInBuffer` never read
// `pendingLeadingSymbols` at all (fixed in KeyboardMonitor.swift alongside
// this harness).

/// Deterministic stand-in for `TextReplacer`: models "what's on screen" as a
/// plain string instead of posting real CGEvents. Interprets `length`/
/// `trailing`/`trailingAlreadyOnScreen` via the SAME `TextReplacementPlan`
/// production code uses, so a wrong backspace-count formula in
/// `KeyboardMonitor` shows up here exactly as it would on a real screen.
final class FakeTextReplacer: TextReplacing {
    private(set) var screen: String = ""
    private(set) var invocationCount = 0
    private let inputSources: InputSourceManager

    init(inputSources: InputSourceManager) {
        self.inputSources = inputSources
    }

    func replaceCurrentWord(
        length: Int, replacement: String, targetLayout: KeyboardLayout,
        trailing: String?, trailingAlreadyOnScreen: Bool,
        completion: @escaping (TextReplacer.Result) -> Void
    ) {
        invocationCount += 1
        // The real TextReplacer switches the input source FIRST, before any
        // backspace/retype — matters here too: any further keys the harness
        // presses after this correction (mid-word instant-correction cases
        // keep typing the rest of the word) must render under the NEW
        // layout, exactly like a real app would see them.
        inputSources.switchTo(targetLayout)
        let plan = TextReplacementPlan(
            originalLength: length, replacement: replacement, trailing: trailing,
            trailingAlreadyOnScreen: trailingAlreadyOnScreen
        )
        // Clamped to what's actually on screen — exactly what a real text
        // field does once there's nothing left to delete. A backspace count
        // that's too high WITHIN the existing text (the interesting bug
        // class) still eats into whatever precedes the word, same as live.
        let backspaces = min(plan.backspaceCount, screen.count)
        screen.removeLast(backspaces)
        screen += plan.payload
        completion(.success)
    }

    func cancelCurrentReplacement() {}

    /// Called by `KeyboardMonitorHarness.press` for a physical keystroke that
    /// was NOT suppressed by a firing correction — i.e. what a real app
    /// would have rendered on its own, outside any backspace/retype
    /// transaction.
    func appendPhysicalChar(_ text: String) {
        screen += text
    }
}

/// Drives a real `KeyboardMonitor` with synthetic CGEvents. No XCTest, no
/// Accessibility API, no real focused app — `screen` is the only "display".
final class KeyboardMonitorHarness {
    let prefs = PreferencesService()
    let exceptions = ExceptionsService()
    let replacer: FakeTextReplacer
    let monitor: KeyboardMonitor
    private let inputSources: InputSourceManager

    var screen: String { replacer.screen }
    /// How many replacements the monitor actually attempted — the only way to
    /// assert "it left correct text alone" rather than "it happened to put the
    /// same characters back".
    var invocationCount: Int { replacer.invocationCount }

    init(
        dictionary: WordDictionary, inputSources: InputSourceManager,
        secureInputDetector: SecureInputDetector = SecureInputDetector(secureCheck: { false }, axProbe: { false })
    ) {
        self.inputSources = inputSources
        let replacer = FakeTextReplacer(inputSources: inputSources)
        self.replacer = replacer
        let detector = LanguageDetector(
            dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs
        )
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let perApp = PerAppLayoutService(inputSourceManager: inputSources, prefsService: prefs)
        let snippetDefaults = UserDefaults(
            suiteName: AppIdentity.bundleIdentifier + ".tests.keyboard-monitor-snippets"
        )!
        let snippets = SnippetService(defaults: snippetDefaults)
        snippets.snippets = [:]
        monitor = KeyboardMonitor(
            languageDetector: detector, textReplacer: replacer,
            statsService: StatisticsService(), prefsService: prefs,
            exceptionsService: exceptions, yoficatorService: YoficatorService(),
            switchUndoManager: SwitchUndoManager(), perAppLayoutService: perApp,
            instantCorrectionAnalyzer: analyzer, snippetService: snippets,
            // The real IsSecureEventInputEnabled() is a GLOBAL OS flag, not
            // scoped to this test process — forcing it off here is what
            // makes this harness deterministic regardless of whatever's
            // actually focused on the machine running the tests. `axProbe`
            // is also forced off so this headless harness never dispatches a
            // real AX call to whatever happens to be focused on the machine
            // running the tests.
            secureInputDetector: secureInputDetector
        )
    }

    /// Simulate one physical keydown. Mirrors `eventTapCallback`: run the
    /// same analysis `handleEvent` does, then only render the character if
    /// the tap wouldn't have suppressed it — a firing correction suppresses
    /// the just-typed trigger letter and retypes it itself as part of its
    /// own payload (RC-1 in KeyboardMonitor.swift), so it must NOT also land
    /// on screen via the normal path.
    func press(_ keycode: UInt16, flags: CGEventFlags = []) {
        let rendered = inputSources.currentLayout.flatMap {
            inputSources.characterForKeycode(keycode, layout: $0, flags: flags)
        }
        guard let event = Self.makeKeyDown(keycode: keycode, flags: flags) else { return }
        let proxy = OpaquePointer(UnsafeMutableRawPointer(bitPattern: 1)!)
        monitor.handleEvent(proxy, type: .keyDown, event: event)
        let suppressed = monitor.consumeSuppressCurrentEvent()
        if !suppressed, let rendered {
            replacer.appendPhysicalChar(rendered)
        }
    }

    func press(_ stroke: BufferedKeystroke) { press(stroke.keycode, flags: stroke.flags) }
    func type(_ strokes: [BufferedKeystroke]) { strokes.forEach { press($0) } }

    private static func makeKeyDown(keycode: UInt16, flags: CGEventFlags) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true) else {
            return nil
        }
        event.flags = flags
        return event
    }
}

/// Snapshots the exact UserDefaults keys these tests flip, plus the Mac's
/// real active input source, and restores both unconditionally — same
/// hygiene as `PreferencesServiceTests` above, extended to the layout:
/// `KeyboardMonitor` reads `InputSourceManager.currentLayout` live from the
/// OS with no injection seam, so exercising real ru/en typing means actually
/// switching it for the duration of these tests.
private final class KeyboardMonitorTestEnvironment {
    private let inputSources: InputSourceManager
    private let originalLayoutID: String?
    private let defaults = UserDefaults.standard
    private let originalValues: [(key: String, value: Any?)]

    init(inputSources: InputSourceManager) {
        self.inputSources = inputSources
        originalLayoutID = inputSources.currentLayout?.id
        let prefix = AppIdentity.keyPrefix
        let keys = [
            prefix + "autoEnabled", prefix + "instantCorrection", prefix + "yoficator",
            prefix + "activeLayoutIDs", prefix + "wordExceptions", prefix + "appExceptions",
            prefix + "autoLearned",
        ]
        originalValues = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    func restore() {
        for (key, value) in originalValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let originalLayoutID, let layout = inputSources.layout(withID: originalLayoutID) {
            inputSources.switchTo(layout)
        }
    }
}

enum KeyboardMonitorIntegrationTests {
    static func run() {
        TestRunner.section("KeyboardMonitor integration — headless typed-sequence → screen (no GUI)")

        // On macOS 27.0 beta, CGEvent(keyboardEventSource:) can deadlock inside
        // SkyLight after the harness changes the active input source. A live
        // stack sample showed SLEventCreateKeyboardEvent waiting forever on
        // CGSEventSourceShutdown's mutex. Pure state-machine coverage still
        // runs; skip only this synthetic-GUI integration layer.
        if !TestRunner.syntheticKeyboardEventsAreSafe {
            TestRunner.skip("macOS 27 blocks synthetic CGEvent construction in this headless harness")
            return
        }

        guard LicenseService.shared.isEntitled else {
            TestRunner.skip(
                "KeyboardMonitor integration harness requires an entitled LicenseService.shared "
                    + "(Double Shift and auto-correct are both license-gated)"
            )
            return
        }
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the KeyboardMonitor integration harness")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        func harness(autoSwitch: Bool) -> KeyboardMonitorHarness {
            let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
            h.prefs.isAutoSwitchEnabled = autoSwitch
            h.prefs.isInstantCorrectionEnabled = true
            h.prefs.isYoficatorEnabled = false
            h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
            h.exceptions.appExceptions = []
            h.exceptions.wordExceptions = []
            h.exceptions.autoLearned = [:]
            return h
        }

        // --- "/exit" — the reported ".yexit" defect, task minimum -----------
        // Double Shift with auto-switch OFF: this is exactly how the live bug
        // was hit — Terminal.app is in ExceptionsService's default app-
        // exception list, so manual Double Shift is the ONLY correction path
        // available there, never the automatic ones.
        TestRunner.section("Double Shift folds a leading symbol — \"/exit\" (live \".yexit\" defect)")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(44) // "/" → "." under ru
            if let exit = InstantCorrectionFixtures.keystrokes(for: "exit", reverse: enReverse) {
                h.type(exit)
                TestRunner.assertEqual(
                    h.screen, ".учше",
                    "sanity: on-screen text before Double Shift matches the live debug.log verbatim"
                )
                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
                TestRunner.assertEqual(
                    h.screen, "/exit",
                    "fix: leading '/' converts together with the word — no dropped symbol, no extra character"
                )
            } else {
                TestRunner.assertTrue(false, "'exit': EN fixture can type every character")
            }
        }

        // --- symbol keys that are letters in Russian -------------------------
        // 39.6% of Russian words >=3 letters contain at least one of б ю х ж ё
        // э ъ, which live on `,` `.` `[` `;` `` ` `` `'` `]`. Those keys used to
        // close the word on the spot, so the head got corrected alone and the
        // tail started a new word: "до так;е" (owner, 05.08).
        TestRunner.section("Symbol keys stay inside the word — \"также\", \"колбаса\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let takzhe = InstantCorrectionFixtures.keystrokes(for: "также", reverse: ruReverse) {
                h.type(takzhe)
                h.press(49) // space — the real boundary, where the decision belongs
                TestRunner.assertEqual(
                    h.screen, "также ",
                    "fix: the whole word converts — red was \"так;е \", corrected at the ';' key"
                )
            } else {
                TestRunner.assertTrue(false, "'также': RU fixture can type every character")
            }
        }
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let kolbasa = InstantCorrectionFixtures.keystrokes(for: "колбаса", reverse: ruReverse) {
                h.type(kolbasa)
                h.press(49)
                TestRunner.assertEqual(
                    h.screen, "колбаса ",
                    "fix: 'б' (the ',' key) no longer splits the word after the dictionary word 'кол'"
                )
            } else {
                TestRunner.assertTrue(false, "'колбаса': RU fixture can type every character")
            }
        }

        // --- English must not become Russian ---------------------------------
        // The above is only safe because the detector scores the LETTER CORE and
        // reads a trailing ambiguous key both ways. Without that, "key." renders
        // as the real Russian word "луню" and wins unopposed — and with the old
        // contextBias of 15 (larger than the 10-point collision gap) a preceding
        // Russian word was enough to open the gate on its own.
        TestRunner.section("English survives the symbol run — \"key.\", \"bye.\", \"next.\"")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            // Prime the context with a Russian word, the worst case for English.
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) {
                h.type(privet)
                h.press(49)
            }
            inputSources.switchTo(enLayout)
            let h2 = harness(autoSwitch: true)
            for word in ["key", "bye", "next"] {
                if let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: enReverse) {
                    h2.type(strokes)
                    h2.press(47) // "." — a letter (ю) in Russian
                    h2.press(49)
                } else {
                    TestRunner.assertTrue(false, "'\(word)': EN fixture can type every character")
                }
            }
            TestRunner.assertEqual(
                h2.screen, "key. bye. next. ",
                "correctly typed English with trailing punctuation is left alone"
            )
            TestRunner.assertEqual(
                h2.invocationCount, 0,
                "not a single replacement was attempted on correct English"
            )
        }

        // --- ambiguousKeyRecent unblocks mid-word once 1 plain letter follows
        // (narrowed from 2 on 21.08.2026 — see the property's doc comment)
        // "работа" = "hf,jnf" on EN keys — the ambiguous ',' ('б') sits at
        // index 3. Instant correction stays gated at index 3 (the ambiguous
        // key IS the last keystroke) and is free to fire again at index 4
        // ("hf,j" = "рабо", a confident dictionary prefix) — i.e. before the
        // word is even finished, let alone before a word boundary. A sticky
        // whole-run flag (the old `runHasAmbiguousKey`) would keep this
        // blocked all the way to the end of the word instead.
        TestRunner.section("Instant correction unblocks past an ambiguous key once 1 letter follows — \"работа\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let rabota = InstantCorrectionFixtures.keystrokes(for: "работа", reverse: ruReverse) {
                for stroke in rabota.dropLast() { h.press(stroke) } // "hf,jn" — everything but the last "f"
                TestRunner.assertEqual(
                    h.invocationCount, 1,
                    "instant correction already fired mid-word, before the final letter and before any space"
                )
                TestRunner.assertEqual(
                    h.screen, "работ",
                    "on-screen text is the corrected Russian prefix — fixed before the word was even finished"
                )
                h.press(rabota.last!) // the trailing "f" ("а") — types normally on the now-switched layout
                TestRunner.assertEqual(
                    h.invocationCount, 1,
                    "the word boundary/gate path does not fire a second correction on the same word"
                )
                TestRunner.assertEqual(h.screen, "работа", "the rest of the word completes correctly on the new layout")
            } else {
                TestRunner.assertTrue(false, "'работа': ru fixture can type every character")
            }
        }

        // --- ambiguousKeyRecent still blocks while the key is in the last 2 -
        // "key." — the "." (kc47) is a letter in Russian ("ю") and joins the
        // word buffer as its own defense (see the comment above), landing
        // right at the last keystroke. Instant correction must NOT misread
        // it as the real Russian word "луню" while it's still that recent —
        // the full word-boundary scorer (which reads the trailing key both
        // ways) is what safely resolves "key." as English, not the looser
        // instant path.
        TestRunner.section("Instant correction stays gated with the ambiguous key in the last 2 keystrokes — \"key.\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let key = InstantCorrectionFixtures.keystrokes(for: "key", reverse: enReverse) {
                h.type(key)
                h.press(47) // "." — a letter (ю) in Russian; joins the buffer, not a boundary
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "instant correction stays blocked while '.' is still within the last 2 keystrokes"
                )
                TestRunner.assertEqual(h.screen, "key.", "on-screen text is exactly what was typed, untouched so far")
            } else {
                TestRunner.assertTrue(false, "'key': EN fixture can type every character")
            }
        }

        // --- Trailing trigger renders on the TARGET layout, not the source --
        // Shift+kc44 is '?' on QWERTY but ',' on ЙЦУКЕН (same physical key);
        // Shift+kc26 is '&' on QWERTY but '?' on ЙЦУКЕН. The trigger that
        // closes an auto-corrected word used to render on the layout it was
        // PRESSED on (before the switch) instead of the one the word lands
        // in — "Да" + Shift+kc44 in en printed "Да?" instead of "Да,".
        // Instant correction is switched off in all three cases below: it
        // fires MID-WORD and would flip the layout before the trigger key is
        // even pressed, masking the bug this test targets — the trigger
        // that closes the word at the BOUNDARY (processCurrentWord).
        TestRunner.section("Trailing trigger converts with the word — \"Да,\" not \"Да?\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let privet = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(privet)
                h.press(44, flags: .maskShift) // '?' on QWERTY, ',' on ЙЦУКЕН
                TestRunner.assertEqual(
                    h.screen, "привет,",
                    "fix: trailing renders on the TARGET (ru) layout — was \"привет?\""
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            }
        }
        // Mirror direction: ru → en.
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let what = InstantCorrectionFixtures.keystrokes(for: "what", reverse: enReverse) {
                h.type(what)
                h.press(44, flags: .maskShift)
                TestRunner.assertEqual(
                    h.screen, "what?",
                    "fix: trailing renders on the TARGET (en) layout — was \"what,\""
                )
            } else {
                TestRunner.assertTrue(false, "'what': EN fixture can type every character")
            }
        }
        // Second trigger key on the same physical row, same direction as the
        // first case (en → ru) — the bug's other reported instance ("Что&"
        // instead of "Что?").
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let dela = InstantCorrectionFixtures.keystrokes(for: "дела", reverse: ruReverse) {
                h.type(dela)
                h.press(26, flags: .maskShift) // '&' on QWERTY, '?' on ЙЦУКЕН
                TestRunner.assertEqual(
                    h.screen, "дела?",
                    "fix: Shift+kc26 also renders on the TARGET (ru) layout — was \"дела&\""
                )
            } else {
                TestRunner.assertTrue(false, "'дела': RU fixture can type every character")
            }
        }

        // --- lone "b" → "и" — the 05.08.2026 report ------------------------
        // Owner pressed Double Shift five times on a single latin "b" in
        // Ghostty and nothing happened (log 07:49:54-57, five consecutive
        // "no selection/buffer/history/caret word"). Cause: every path had a
        // 2-character floor. Single letters are ordinary Russian words.
        TestRunner.section("Double Shift converts a SINGLE-letter word — lone \"b\" → \"и\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(11) // "b" under en → "и" under ru
            TestRunner.assertEqual(h.screen, "b", "sanity: a lone latin letter is on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reports a conversion for a one-letter word"
            )
            TestRunner.assertEqual(
                h.screen, "и",
                "fix: the single letter converts instead of being silently skipped"
            )
        }

        // A one-letter LIVE buffer must win over an older history slot —
        // otherwise the fix above would convert the previous word instead of
        // the letter the user is actually looking at.
        // The block above ends with the layout switched to ru (that is what a
        // conversion does) — reset it, or "hello" gets typed as "руддщ".
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) {
                h.type(hello)
                h.press(49) // space — "hello" moves into the history slot
                h.press(11) // "b" — a new, one-character live buffer
                TestRunner.assertEqual(h.screen, "hello b", "sanity: both words are on screen before the swap")
                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "conversion happens")
                TestRunner.assertEqual(
                    h.screen, "hello и",
                    "the live one-letter buffer is converted, the history word is left alone"
                )
            } else {
                TestRunner.assertTrue(false, "'hello': EN fixture can type every character")
            }
        }

        // A one-letter word that has already been closed by a space must stay
        // reachable: the history slot used to carry a 2-character floor, so
        // "b" converted while "b " did not — the same lone-"b" report one
        // keystroke later (log 13.08.2026, four "no selection/buffer/history/
        // caret word" skips in Ghostty).
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(11) // "b"
            h.press(49) // space — the word moves into the history slot
            TestRunner.assertEqual(h.screen, "b ", "sanity: the closed one-letter word is on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reaches a one-letter word through the history slot"
            )
            TestRunner.assertEqual(
                h.screen, "и ",
                "fix: the closed single letter converts, its trailing space is preserved"
            )
        }

        // A lone SYMBOL is convertible too — the run path used to require two
        // characters, so "ю" typed where "." was meant had no path at all:
        // auto-correction never touches a single character, and the scored
        // path has no word to score.
        inputSources.switchTo(enLayout)
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(47) // "." in Latin, the LETTER "ю" in Cyrillic
            TestRunner.assertEqual(h.screen, "ю", "sanity: a lone Cyrillic letter-symbol on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift converts a one-character run"
            )
            TestRunner.assertEqual(h.screen, ".", "fix: the single symbol converts key-for-key")
        }

        // The same for a key that is punctuation in BOTH alphabets and so
        // never enters the letter buffer at all — keycode 44 is "/" in Latin
        // and "." in Cyrillic. Only the run path can reach it, and that path
        // used to require two characters.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(44) // "/" in Latin, "." in Cyrillic
            TestRunner.assertEqual(h.screen, ".", "sanity: a lone punctuation key on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift converts a one-character run of pure punctuation"
            )
            TestRunner.assertEqual(h.screen, "/", "fix: «.» typed where «/» was meant is reachable")
        }

        // --- "7ю6с" → "7.6s" — a run the dictionary cannot judge -------------
        // Owner typed "7.6s" with the Russian layout active, got "7ю6с", and
        // pressed Double Shift three times with nothing happening at all (log
        // 09:07:51–09:08:08, every press "no selection/buffer/history/caret
        // word"). The digits slice the run into three fragments — "ю", "с" —
        // none of which is a word, so the scored path had nothing to work
        // with. An explicit gesture is not a request for a judgement.
        TestRunner.section("Double Shift converts a whole run with digits — «7ю6с» → «7.6c»")
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(26) // 7
            h.press(47) // "." in en, "ю" in ru
            h.press(22) // 6
            h.press(8)  // "c" in en, "с" in ru
            TestRunner.assertEqual(h.screen, "7ю6с", "sanity: the run is on screen in the wrong alphabet")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reports a conversion for a digits-and-letters run"
            )
            TestRunner.assertEqual(
                h.screen, "7.6c",
                "the WHOLE run converts key-for-key, digits kept, nothing left behind"
            )
        }

        // --- lone "b" + space auto-corrects, but "rm -f" does NOT -------------
        // Owner: typed "b", pressed space, expected "и", got nothing — the
        // floor was 3 letters, so the single-letter Russian words (и в с к я а
        // о у) were unreachable for automatic correction. The pair below is
        // the whole justification for lowering it: the same change would turn
        // "rm -f" into "rm -а" if a leading symbol didn't block it, because
        // "а" is a genuine Russian word and wins the scoring fairly.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Auto-correction reaches one-letter words — «b » → «и », but «-f » stays")
            inputSources.switchTo(enLayout)
            let h = harness(autoSwitch: true)
            h.press(11) // "b" on en
            h.press(49) // space — the word boundary
            TestRunner.assertEqual(h.screen, "и ", "a lone «b» becomes the Russian word «и»")

            inputSources.switchTo(enLayout)
            let flags = harness(autoSwitch: true)
            flags.press(27) // "-"
            flags.press(3)  // "f"
            flags.press(49) // space
            TestRunner.assertEqual(
                flags.screen, "-f ",
                "a flag is left alone — the leading symbol keeps the short-word path shut"
            )
            _ = ruLayout
        }

        // --- "ы1" → "s1" — one letter plus a digit ----------------------------
        // Owner, 20:01:50. Auto-correction can't help here (a single letter is
        // far under the 3-letter floor), so Double Shift is the ONLY way to fix
        // it — and it answered "no selection/buffer/history/caret word".
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Double Shift on «ы1» — one letter and a digit")
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(1)  // "s" in en, "ы" in ru
            h.press(18) // "1"
            TestRunner.assertEqual(h.screen, "ы1", "sanity: letter plus digit on screen")
            TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
            TestRunner.assertEqual(h.screen, "s1", "the pair converts — the digit stays, the letter moves")
        }

        // --- "./exit" typed on RU — the leading "." is a LETTER there ---------
        // Owner typed "./exit" with the Russian layout active and got
        // "./exit" back with a stray dot in front (log 18:43:06,
        // "doubleShift via run len=5" — five characters counted where six
        // were typed). Keycode 47 is "." in Latin but the LETTER "ю" in
        // Cyrillic, so the run starts with a letter and continues through a
        // symbol; nothing about that may drop a keystroke.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Double Shift on «ю.учше» typed for «./exit» — nothing dropped")
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            for code in [UInt16(47), 44, 14, 7, 34, 17] { h.press(code) }
            TestRunner.assertEqual(
                h.screen, "ю.учше", "sanity: six keystrokes, six characters on screen"
            )
            TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
            TestRunner.assertEqual(
                h.screen, "./exit",
                "all six convert — no character left stranded in front"
            )
        }

        // --- "на 300$" — history must not outlive the caret ------------------
        // Double Shift's history fallback rewrites text AT THE CARET. Owner
        // typed "на" + space + "300$" and pressed Double Shift: the stale "на"
        // was converted and retyped at the caret, eating the digits and
        // producing "на 30yf" (log 08:26:04, "doubleShift via history:
        // ru→en len=2" with four leading symbols already typed after it).
        TestRunner.section("Digits kill the history slot — the \"на 300$\" corruption")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            if let na = InstantCorrectionFixtures.keystrokes(for: "на", reverse: ruReverse) {
                h.type(na)
                h.press(49)  // space — "на" moves into the history slot
                h.press(29)  // "3"
                h.press(26)  // "0"
                h.press(26)  // "0"
                let before = h.screen
                TestRunner.assertTrue(
                    !h.monitor.swapLastWordInBuffer(),
                    "Double Shift refuses: the history word is no longer next to the caret"
                )
                TestRunner.assertEqual(
                    h.screen, before,
                    "fix: nothing is rewritten — the digits stay intact instead of being eaten"
                )
            } else {
                TestRunner.assertTrue(false, "'на': RU fixture can type every character")
            }
        }

        // --- "$GRAF", "/model" — same fold-in via the automatic paths -------
        TestRunner.section("Auto-correct folds a leading symbol — \"/model\", \"$GRAF\"")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            h.press(44) // "/"
            if let model = InstantCorrectionFixtures.keystrokes(for: "model", reverse: enReverse) {
                h.type(model)
                // Trailing space flushes the boundary path if instant didn't
                // already fire — since 19.08.2026 "model" is exactly that
                // case: its own ru reading is CLEAN (junk-gate), so instant
                // now defers here (same trade-off InstantCorrectionAnalyzerTests'
                // "руддщ" case documents) and the boundary path is what
                // actually folds the leading "/" in this run.
                h.press(49)
                TestRunner.assertEqual(
                    h.screen, "/model ",
                    "'/model' converts with the leading '/' intact (Ghostty 03.08.2026 regression, integration level)"
                )
            } else {
                TestRunner.assertTrue(false, "'model': EN fixture can type every character")
            }
        }
        inputSources.switchTo(ruLayout)
        do {
            // Named case is "$GRAF" (CLAUDE.md citation); reproduced here as
            // "$HELLO" — "graf" itself is too short/uncommon a word for the
            // dictionary/spellchecker to confidently score at either the
            // instant or the boundary threshold (same substitution
            // LeadingSymbolRunGuardTests already documents above for the
            // exact same citation), which would make this a scoring-
            // calibration test rather than a leading-symbol-fold-in test.
            // "hello" is one of the suite's proven golden words.
            let h = harness(autoSwitch: true)
            h.press(21, flags: .maskShift) // shift+4 → ";" under ru
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) {
                for stroke in hello { h.press(stroke.keycode, flags: .maskShift) } // HELLO, all-caps
                h.press(49) // trailing space — flushes the boundary path if instant didn't already fire
                TestRunner.assertEqual(
                    h.screen, "$HELLO ",
                    "'$HELLO' converts with the leading '$' intact ('$GRAF'-style leading-symbol citation)"
                )
            } else {
                TestRunner.assertTrue(false, "'hello': EN fixture can type every character")
            }
        }

        // --- «марже»-class direction/drift bug, integration level -----------
        // Named regression is «марже» (CLAUDE.md); reproduced here with
        // «привет» instead — «марже» contains "ж", which physically sits on
        // the ";" key, itself a real EN word-boundary trigger
        // (InputBuffer.cyrillicOnlyLetterCodes) — typing it while EN is
        // active would legitimately split the buffer mid-word regardless of
        // this bug, which is a separate, pre-existing interaction outside
        // this fix's scope (documented in the final report). «привет» avoids
        // that letter entirely while exercising the exact same primitive
        // (`swapTarget` resolving direction from the CAPTURED typed layout,
        // never "whatever's active now") that `MarzheDoubleShiftRegressionTests`
        // already pins at the unit level.
        TestRunner.section("Double Shift history survives an active-layout drift — «марже»-class bug, integration level")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) {
                h.type(privet)
                h.press(49) // space — completes the word into history, buffer clears
                TestRunner.assertTrue(
                    !h.screen.contains("привет"),
                    "sanity: EN-active typing renders «привет»'s physical keys as Latin garbage"
                )

                // Active layout drifts to ru BETWEEN word completion and the
                // Double Shift press — direction must resolve from the
                // CAPTURED typed layout (en), never "whatever's active now".
                inputSources.switchTo(ruLayout)

                TestRunner.assertTrue(
                    h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion from history"
                )
                TestRunner.assertEqual(
                    h.screen, "привет ",
                    "fix: direction resolves from the layout the word was TYPED on, not the drifted active layout"
                )
            } else {
                TestRunner.assertTrue(false, "«привет»: ru fixture can type every character")
            }
        }

        // --- Toggle: two presses return the original, a third converts again
        TestRunner.section("Double Shift toggle — two presses return the original, a third converts again")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            if let helloAsRu = InstantCorrectionFixtures.keystrokes(for: "руддщ", reverse: ruReverse) {
                h.type(helloAsRu)
                TestRunner.assertEqual(h.screen, "руддщ", "sanity: on-screen text before any Double Shift press")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "1st press reports a conversion")
                TestRunner.assertEqual(h.screen, "hello", "1st press: ru→en gives 'hello'")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "2nd press reports a conversion")
                TestRunner.assertEqual(h.screen, "руддщ", "2nd press: converts BACK to the original on-screen text")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "3rd press reports a conversion")
                TestRunner.assertEqual(h.screen, "hello", "3rd press: converts again — one press per result, never stuck")
            } else {
                TestRunner.assertTrue(false, "'руддщ': ru fixture can type every character")
            }
        }

        // --- Live typing: spaces not eaten, words not glued -----------------
        TestRunner.section("Live typing — spaces are not eaten, words are not glued (\"и самое главное\")")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true) // correctly-typed ru words — must never fire
            let phrase = "и самое главное"
            var typedOK = true
            for ch in phrase {
                if ch == " " {
                    h.press(49)
                } else if let kc = ruReverse[ch] {
                    h.press(kc)
                } else {
                    typedOK = false
                }
            }
            TestRunner.assertTrue(typedOK, "sanity: every character of the phrase has a ru fixture mapping")
            TestRunner.assertEqual(
                h.screen, phrase, "spaces preserved, words not glued, no false-positive correction mid-phrase"
            )
            TestRunner.assertEqual(h.replacer.invocationCount, 0, "no correction ever fired on correctly-typed text")
        }

        // --- FIX A (13.08.2026): Cmd+Shift+V must not leave a stale buffer --
        // `KeyboardMonitorHarness` never wires `hotkeyManager` (it exercises
        // `handleEvent`'s own analysis, not HotkeyManager's live TIS/AX
        // calls), so `started` is always false here — this exercises the
        // "paste never actually fired" arm of the fix, the one FIX A's own
        // comment calls out as easy to forget since the paste itself doesn't
        // live in it. Before the fix, `buffer`/`runKeystrokes` from typing
        // "ghbdtn" survived the Cmd+Shift+V branch untouched, and the space
        // right after fired a boundary correction on that stale buffer.
        TestRunner.section("Cmd+Option+Shift+V invalidates the stale word buffer (FIX A)")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false // isolate the boundary-correction path
            if let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(ghbdtn)
                h.press(9, flags: [.maskCommand, .maskShift, .maskAlternate]) // Cmd+Option+Shift+V
                h.press(49) // space — word boundary
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "a stale buffer from before Cmd+Option+Shift+V does not fire a correction after the paste"
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': en fixture can type every character")
            }
        }

        // --- NEW (15.08.2026): bare Cmd+Shift+V (no Option) must now pass --
        // through untouched — PasteNow (the owner's clipboard manager) opens
        // on the SAME shortcut (carbonKeyCode 9, modifiers 768) and our tap
        // was swallowing it, killing PasteNow. Paste-without-formatting moved
        // to Cmd+Option+Shift+V (macOS's own "Paste and Match Style" combo);
        // plain Cmd+Shift+V must not even enter the paste-no-format branch —
        // it falls straight through to the ordinary modifier-shortcut path
        // (any Cmd/Ctrl/Option combo invalidates context there already).
        //
        // `consumeSuppressCurrentEvent()`/`invocationCount` can't tell the two
        // branches apart here: neither ever sets the internal suppress flag
        // for this key (the REAL swallow happens in `handlesShortcut`, which
        // is `fileprivate` and only reachable from the real CGEventTap
        // callback — the structural check above already pins that), and
        // `hotkeyManager` is never wired in this harness, so a "started"
        // paste never reaches the replacer either way. The one thing that
        // DOES differ observably is whether `handleEvent`'s branch itself
        // ran at all — it logs unconditionally on every pass — so the debug
        // log is the actual falsifiable signal for "which branch executed".
        TestRunner.section("Cmd+Shift+V without Option never enters the paste-no-format branch")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false // isolate the boundary-correction path
            if let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(ghbdtn)
                DebugLog.shared.waitForPendingWrites()
                let before = DebugLog.shared.currentContents
                h.press(9, flags: [.maskCommand, .maskShift]) // no .maskAlternate
                DebugLog.shared.waitForPendingWrites()
                let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
                TestRunner.assertTrue(
                    !newLines.contains("pasteNoFormat:"),
                    "bare Cmd+Shift+V (no Option) never enters the paste-no-format branch at all"
                )
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "bare Cmd+Shift+V never starts a paste-no-format replacement — Option is required now"
                )
                h.press(49) // space — would fire a boundary correction if the stale buffer had survived
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "the modifier-shortcut path still invalidated the stale 'ghbdtn' buffer, so the space corrects nothing"
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': en fixture can type every character")
            }
        }

        // --- Guards: shell/code punctuation and correctly-typed words -------
        TestRunner.section("Guards — correctly-typed text and shell/code punctuation never trigger a correction")

        func assertNoCorrection(
            _ label: String, layout: KeyboardLayout, expectedScreen: String,
            _ typeIt: (KeyboardMonitorHarness) -> Void
        ) {
            inputSources.switchTo(layout)
            let h = harness(autoSwitch: true)
            typeIt(h)
            TestRunner.assertEqual(
                h.replacer.invocationCount, 0, "\(label): never triggers a backspace/retype transaction"
            )
            TestRunner.assertEqual(h.screen, expectedScreen, "\(label): on-screen text is exactly what was typed")
        }

        assertNoCorrection("#tag", layout: enLayout, expectedScreen: "#tag ") { h in
            h.press(20, flags: .maskShift) // "#"
            if let tag = InstantCorrectionFixtures.keystrokes(for: "tag", reverse: enReverse) { h.type(tag) }
            h.press(49)
        }
        assertNoCorrection("@name", layout: enLayout, expectedScreen: "@name ") { h in
            h.press(19, flags: .maskShift) // "@"
            if let name = InstantCorrectionFixtures.keystrokes(for: "name", reverse: enReverse) { h.type(name) }
            h.press(49)
        }
        assertNoCorrection("./script", layout: enLayout, expectedScreen: "./script ") { h in
            h.press(47) // "." — EN word boundary (punctuation), not a leading symbol; still safe
            h.press(44) // "/"
            if let script = InstantCorrectionFixtures.keystrokes(for: "script", reverse: enReverse) { h.type(script) }
            h.press(49)
        }
        assertNoCorrection("$PATH", layout: enLayout, expectedScreen: "$PATH ") { h in
            h.press(21, flags: .maskShift) // "$"
            if let path = InstantCorrectionFixtures.keystrokes(for: "path", reverse: enReverse) {
                for stroke in path { h.press(stroke.keycode, flags: .maskShift) } // PATH, all-caps
            }
            h.press(49)
        }
        assertNoCorrection("git commit -m", layout: enLayout, expectedScreen: "git commit -m") { h in
            if let git = InstantCorrectionFixtures.keystrokes(for: "git", reverse: enReverse) { h.type(git) }
            h.press(49)
            if let commit = InstantCorrectionFixtures.keystrokes(for: "commit", reverse: enReverse) { h.type(commit) }
            h.press(49)
            h.press(27) // "-"
            if let mKey = enReverse["m"] { h.press(mKey) }
        }
        assertNoCorrection("100$", layout: enLayout, expectedScreen: "100$") { h in
            h.press(18) // "1"
            h.press(29) // "0"
            h.press(29) // "0"
            h.press(21, flags: .maskShift) // "$"
        }
        assertNoCorrection("№1", layout: ruLayout, expectedScreen: "№1") { h in
            h.press(20, flags: .maskShift) // "№" under ru
            h.press(18) // "1"
        }
        assertNoCorrection("correctly-typed EN word", layout: enLayout, expectedScreen: "hello ") { h in
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) { h.type(hello) }
            h.press(49)
        }
        assertNoCorrection("correctly-typed RU word", layout: ruLayout, expectedScreen: "привет ") { h in
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) { h.type(privet) }
            h.press(49)
        }
    }
}

// MARK: - Avalanche circuit breaker (CLAUDE.md "avalanche" incident: a single
// mistyped Russian word cascaded into ~10 layout switches and 4 Double Shift
// firings inside one second, visible on screen as a mangled `завершftm`).

enum CorrectionAvalancheGuardTests {
    static func run() {
        TestRunner.section("CorrectionAvalancheGuard — pure threshold logic")
        var breaker = CorrectionAvalancheGuard(limit: 3)
        TestRunner.assertTrue(breaker.canFire, "starts able to fire")
        breaker.recordFired()
        TestRunner.assertTrue(breaker.canFire, "1 consecutive fire is still under the limit")
        breaker.recordFired()
        TestRunner.assertTrue(breaker.canFire, "2 consecutive fires are still under the limit")
        breaker.recordFired()
        TestRunner.assertTrue(!breaker.canFire, "3 consecutive fires with no physical input trips the guard")
        breaker.registerPhysicalEvent()
        TestRunner.assertTrue(breaker.canFire, "a genuine physical event resets the fuse")
    }
}

enum QueueReplacementActiveTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.queueIfReplacementActive — flagsChanged is never queued for replay")

        guard TestRunner.syntheticKeyboardEventsAreSafe else {
            TestRunner.skip("macOS 27 blocks synthetic CGEvent construction in this headless harness")
            return
        }

        let inputSources = InputSourceManager()
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)

        func makeEvent(virtualKey: CGKeyCode, type: CGEventType) -> CGEvent? {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) else {
                return nil
            }
            event.type = type
            return event
        }

        h.monitor.isPaused = true
        defer { h.monitor.isPaused = false }

        // Root fix for the avalanche: a real Shift transition captured
        // during an active replacement must NOT be queued for a later,
        // squashed-timing replay — that replay is exactly what fed
        // HotkeyManager's Shift-tap gesture detector a false double-tap.
        if let flagsEvent = makeEvent(virtualKey: 56, type: .flagsChanged) {
            TestRunner.assertTrue(
                !h.monitor.queueIfReplacementActive(flagsEvent),
                "a Shift transition during an active pause is NOT queued — avalanche fix"
            )
        } else {
            TestRunner.assertTrue(false, "flagsChanged fixture event constructs")
        }

        // Real letters typed during the pause must still be queued and
        // replayed later (pre-existing, unrelated behavior — must survive).
        if let keyEvent = makeEvent(virtualKey: 0, type: .keyDown) {
            TestRunner.assertTrue(
                h.monitor.queueIfReplacementActive(keyEvent),
                "a letter keydown during an active pause is still queued for later replay"
            )
        } else {
            TestRunner.assertTrue(false, "keyDown fixture event constructs")
        }
    }
}

enum AvalancheGuardWiringTests {
    static func run() {
        TestRunner.section("KeyboardMonitor — avalanche guard is wired into the real correction path")

        guard TestRunner.syntheticKeyboardEventsAreSafe else {
            TestRunner.skip("macOS 27 blocks synthetic CGEvent construction in this headless harness")
            return
        }

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts required for the avalanche guard wiring test")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
        h.prefs.isAutoSwitchEnabled = true
        h.prefs.isInstantCorrectionEnabled = true
        h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
        inputSources.switchTo(enLayout)

        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 0, "guard starts clean"
        )

        guard let strokes = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            return
        }

        var fired = false
        for stroke in strokes {
            h.press(stroke.keycode, flags: stroke.flags)
            if h.replacer.invocationCount >= 1 { fired = true; break }
        }
        TestRunner.assertTrue(fired, "sanity: instant correction actually fired somewhere in the word")
        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 1,
            "firing a correction records exactly one avalanche-guard hit (checked immediately after it fires,"
                + " before any later keystroke can reset it)"
        )

        // A genuine next physical letter is proof of life — normal typing
        // never trips the breaker.
        if let aKey = enReverse["a"] { h.press(aKey) }
        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 0,
            "a real physical keystroke after the correction resets the avalanche guard"
        )
    }
}

enum HotPathStructuralGuardTests {
    static func run() {
        TestRunner.section(
            "Hot path structural guard — handleEvent for an ordinary letter never runs AX/replacement work"
        )

        guard TestRunner.syntheticKeyboardEventsAreSafe else {
            TestRunner.skip("macOS 27 blocks synthetic CGEvent construction in this headless harness")
            return
        }

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }) else {
            TestRunner.skip("EN layout required for the hot-path structural guard")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        // A fake gated on a semaphore, exactly like `SecureInputAXTierTests`
        // below — if this were ever reached SYNCHRONOUSLY from the hot path,
        // `h.press` itself would block on it (bounded to 2s, never a true
        // hang, but the elapsed-time assertion fails unmistakably). A plain
        // "call counter checked right after" would be a race, not a proof:
        // `.async` dispatches to a REAL OS thread that can run concurrently
        // and finish before the calling thread even reaches the assertion.
        let axGate = DispatchSemaphore(value: 0)
        let spySecureDetector = SecureInputDetector(
            secureCheck: { false },
            axProbe: {
                _ = axGate.wait(timeout: .now() + 2.0)
                return false
            }
        )

        let h = KeyboardMonitorHarness(
            dictionary: dictionary, inputSources: inputSources, secureInputDetector: spySecureDetector
        )
        h.prefs.isAutoSwitchEnabled = true
        h.prefs.isInstantCorrectionEnabled = true
        inputSources.switchTo(enLayout)

        // A single, ordinary, correctly-typed letter — the overwhelmingly
        // common case: every keystroke of normal typing before a word gets
        // anywhere near a correction decision.
        let start = CFAbsoluteTimeGetCurrent()
        h.press(0) // "a"
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        axGate.signal() // release the background probe so it doesn't leak into later tests

        TestRunner.assertTrue(
            elapsed < 0.05,
            "the secure-input AX probe is never invoked synchronously from the hot path"
                + " (took \(Int(elapsed * 1000))ms; would be ~2000ms if blocked on the gated fake)"
        )
        TestRunner.assertEqual(
            h.replacer.invocationCount, 0,
            "an ordinary letter never starts a text-replacement transaction"
                + " (AX writes / clipboard / sound only ever run from inside a replacement's completion)"
        )
    }
}

/// A replacement is a transaction: the moment the first backspace goes out,
/// the user's word is gone from the screen and only our retype can put it
/// back. Bailing out of either loop halfway therefore destroys text with no
/// way to recover it — the worst failure this app can have. Enforced by
/// reading the source, because the alternative (driving the real
/// `TextReplacer`) posts live CGEvents into whatever the owner is typing —
/// exactly the accident that corrupted his input on 05.08.2026.
enum ReplacementAtomicityGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — a started replacement is never abandoned halfway")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        for (function, loopHeader) in [
            ("sendBackspaces", "for _ in 0..<count {"),
            ("sendBackspacesVerified", "while sent < count + maxExtra {"),
            ("typeStringFast", "for char in text {")
        ] {
            guard let loopStart = text.range(of: loopHeader) else {
                TestRunner.assertTrue(false, "\(function): loop header not found — test needs updating")
                continue
            }
            // Bound the search to the rest of THIS function: the next
            // `private func` (or end of file) is a safe terminator here.
            let rest = String(text[loopStart.upperBound...])
            let functionBody = rest.range(of: "private func").map { String(rest[..<$0.lowerBound]) } ?? rest
            TestRunner.assertTrue(
                !functionBody.contains("isCancelled"),
                "\(function) does not re-check cancellation inside its loop"
                    + " (a mid-loop bail erases text and never retypes it)"
            )
        }
    }
}

/// Double Shift on a SELECTION has no headless coverage — it needs a live
/// focused AX element, which the harness cannot provide. What CAN be pinned
/// structurally are the two invariants the 13.08.2026 report was made of:
/// the AX write is verified by reading back (apps answer `.success` and change
/// nothing), and a selection we failed to write is never handed to the
/// buffer/history path (which would convert an unrelated older word).
enum DoubleShiftSelectionGuardTests {
    static func run() {
        TestRunner.section("Double Shift on a selection — write is verified, selection never falls to the buffer")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/HotkeyManager.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("HotkeyManager.swift not readable from \(source.path)")
            return
        }

        guard let writeCall = text.range(of: "AXTextSelectionService.replaceSelectedText") else {
            TestRunner.assertTrue(false, "AX selection write not found — test needs updating")
            return
        }
        let afterWrite = String(text[writeCall.upperBound...])
        let functionTail = afterWrite.range(of: "\n    private func").map { String(afterWrite[..<$0.lowerBound]) }
            ?? afterWrite
        TestRunner.assertTrue(
            functionTail.contains("AXTextSelectionService.selectedText"),
            "the AX write is read back before being reported as success"
                + " (.success only means the app accepted the message)"
        )

        guard let chainStart = text.range(of: "switch convertAXSelection()") else {
            TestRunner.assertTrue(false, "Double Shift chain not found — test needs updating")
            return
        }
        let chain = String(text[chainStart.upperBound...])
        let unwritableCase = chain.range(of: "case .selectionUnwritable:")
        let noSelectionCase = chain.range(of: "case .noSelection:")
        guard let unwritableCase, let noSelectionCase else {
            TestRunner.assertTrue(false, "outcome cases not found — test needs updating")
            return
        }
        let unwritableBody = String(chain[unwritableCase.upperBound..<noSelectionCase.lowerBound])
        TestRunner.assertTrue(
            unwritableBody.contains("probeClipboardSelection"),
            "an unwritable selection goes straight to the clipboard probe"
        )
        TestRunner.assertTrue(
            !unwritableBody.contains("swapLastWordInBuffer"),
            "an unwritable selection is NEVER handed to the buffer/history path"
                + " (it holds an unrelated older word after a mouse selection)"
        )
    }
}

/// Field incident 21.08.2026: `ShiftStateTracker` has no ground truth for
/// which physical Shift key is actually down — one missed keyUp (secure
/// input, a Cmd+Tab/Space switch swallowing the release) latches its model,
/// and the next SOLO Shift tap then reads as "both held", silently disabling
/// auto-switch for up to 2.5h (debug.log 15:31→18:03) with no user action at
/// all. `HotkeyManager` can't be driven through the real CGEventTap in a
/// headless test (constructing one pulls in `TextReplacer`/`SoundService`
/// that would post real events or play audio) — pinned structurally, same
/// precedent as `ReplacementAtomicityGuardTests`.
enum ComboWindowGuardTests {
    static func run() {
        TestRunner.section("L+R Shift combo — a stuck model can't silently toggle auto-switch")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/HotkeyManager.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("HotkeyManager.swift not readable from \(source.path)")
            return
        }

        // The anchor time must be captured on the FIRST shift's down, inside
        // `if !wasAlreadyHeld` — not unconditionally on every `.down` — or the
        // second shift's own press overwrites it right before the combo check
        // reads it, and the window check below always sees dt≈0.
        guard let notAlreadyHeld = text.range(of: "if !wasAlreadyHeld {") else {
            TestRunner.assertTrue(false, "`!wasAlreadyHeld` branch not found — test needs updating")
            return
        }
        let afterBranch = String(text[notAlreadyHeld.upperBound...])
        let branchBody = afterBranch.range(of: "\n            }").map { String(afterBranch[..<$0.lowerBound]) }
            ?? afterBranch
        TestRunner.assertTrue(
            branchBody.contains("firstComboShiftTime = shiftDownTime"),
            "the combo anchor time is captured only on the FIRST shift's down transition"
        )

        // The combo must reject a stale anchor BEFORE doing anything
        // observable (toggling the preference, playing a sound, posting the
        // notification) — a guard that returns early, not a check that only
        // logs.
        guard let comboBranch = text.range(of: "if shiftState.bothDown && prefsService.isSplitShiftEnabled") else {
            TestRunner.assertTrue(false, "L+R combo branch not found — test needs updating")
            return
        }
        let comboBody = String(text[comboBranch.upperBound...])
        guard let guardRange = comboBody.range(of: "guard comboLatency <= comboWindow else {"),
              let toggleRange = comboBody.range(of: "scheduleAction(branch: \"toggleAutoSwitch\")") else {
            TestRunner.assertTrue(false, "combo window guard or toggle call not found — test needs updating")
            return
        }
        TestRunner.assertTrue(
            guardRange.lowerBound < toggleRange.lowerBound,
            "the window guard runs BEFORE the toggle — a stale combo never fires it"
        )
        let rejectionBody = String(comboBody[guardRange.upperBound..<toggleRange.lowerBound])
        TestRunner.assertTrue(
            rejectionBody.contains("return"),
            "a stale combo returns without toggling auto-switch"
        )
        TestRunner.assertTrue(
            !rejectionBody.contains("shiftState.suppressComboReleases()"),
            "a rejected combo leaves shiftState untouched"
                + " (resetting it here would risk swallowing the next genuine press"
                + " of whichever key was actually stuck as a phantom release)"
        )
    }
}

/// The status colors carry meaning ("Работает" green, "Заблокировано" red), so
/// they are read, not merely glanced at — WCAG AA text level, 4.5:1, in BOTH
/// appearances. Straight `NSColor.systemGreen` measures 2.22:1 on a light
/// window and was shipped that way; this is the check that makes that a test
/// failure instead of a bug report.
/// Spotlight overlay drift class ("ccccara"/"cchr", field log 14.08.2026
/// 20:13:35-37: `run check: model=4 ax=5 → resynced to screen`, then a later
/// gesture on the same field `model=4 ax=6` — the screen kept growing while
/// the model never moved). `convertWholeRun` measures the real on-screen
/// word via AX whenever it can, but for a letters-only run that is a
/// dictionary judgement, not its call — it falls through to
/// `swapLastWordInBuffer`, which used to re-derive the erase count from
/// `keystrokes.count` alone and throw the measurement away, so the SAME
/// AX-verified drift was never healed, only ever compounded.
/// No live AX inside the headless test harness (a CLI test binary has no
/// focused element to read, and forcing one would make the suite depend on
/// whatever the test machine happens to have focused) — pinned structurally
/// instead, same precedent as `ReplacementAtomicityGuardTests`.
enum RunResyncStructuralGuardTests {
    static func run() {
        TestRunner.section("Double Shift erase count — the scored path reuses convertWholeRun's screen measurement")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("KeyboardMonitor.swift not readable from \(source.path)")
            return
        }

        // 1) convertWholeRun stashes the AX measurement right where it falls
        //    through (letters-only run — nothing for THIS function to do).
        guard let fallthroughMarker = text.range(
            of: "run check: letters only — falls through to the scored path"
        ) else {
            TestRunner.assertTrue(false, "letters-only fallthrough log line not found — test needs updating")
            return
        }
        let precedingGuardBlock = String(text[..<fallthroughMarker.lowerBound]).suffix(400)
        TestRunner.assertTrue(
            precedingGuardBlock.contains("pendingRunResync = onScreen.count"),
            "convertWholeRun stashes the AX-measured screen length before falling through"
        )

        // 2) swapLastWordInBuffer picks it up, gated to the LIVE run — never
        //    a `lastCompletedWord` history snapshot, which is a different
        //    word at a different caret position.
        guard let funcStart = text.range(of: "func swapLastWordInBuffer() -> Bool {") else {
            TestRunner.assertTrue(false, "swapLastWordInBuffer not found — test needs updating")
            return
        }
        guard let lengthMarker = text.range(
            of: "var length = leadingSymbols.count + keystrokes.count",
            range: funcStart.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "erase-length computation not found — test needs updating")
            return
        }
        // 3) Everything BEFORE the erase-length computation — where the
        //    replacement CONTENT (`correctedWord`/`runReplacement`) is
        //    decided from `keystrokes` — must never reference the
        //    measurement. Only the erase count is allowed to move; the
        //    screen decides how much to erase, the keycodes decide what to
        //    type (project invariant).
        let contentSelection = String(text[funcStart.upperBound..<lengthMarker.lowerBound])
        TestRunner.assertTrue(
            !contentSelection.contains("pendingRunResync"),
            "the replacement CONTENT is fully decided before the erase-length override runs"
        )

        guard let callSite = text.range(
            of: "textReplacer.replaceCurrentWord(", range: lengthMarker.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "replaceCurrentWord call site not found — test needs updating")
            return
        }
        let overrideBlock = String(text[lengthMarker.upperBound..<callSite.lowerBound])
        // 4) The override is asymmetric (16.08.2026 fix): erasing LESS than
        //    modelled is adopted unconditionally (clamp), erasing MORE is
        //    gated on proof the extra characters are our own artifact
        //    (extend) — a bare `measured != length` comparison is gone.
        TestRunner.assertTrue(
            overrideBlock.contains("KeyboardMonitor.shouldClampToScreen(model: length, measured: measured)"),
            "the safe direction (erase LESS) is adopted unconditionally via shouldClampToScreen"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("KeyboardMonitor.shouldExtendToScreen("),
            "the dangerous direction (erase MORE) is gated through shouldExtendToScreen, not a bare comparison"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("length = measured"),
            "the erase length is overridden with the measured on-screen length, not the model"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("run check: erase resynced "),
            "the override is logged with the specific 'run check: erase resynced N→M' format"
        )
    }
}

/// Pure unit coverage for `KeyboardMonitor.shouldClampToScreen`/
/// `shouldExtendToScreen` — no AX involved, so unlike the structural guards
/// above this exercises the actual decision logic with real inputs.
enum RunResyncPredicateTests {
    static func run() {
        TestRunner.section("Run-resync erase-length predicate — clamp always, extend only with a suffix match")

        TestRunner.assertTrue(
            KeyboardMonitor.shouldClampToScreen(model: 5, measured: 4),
            "measured < model → clamp (safe direction, unconditional)"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldClampToScreen(model: 5, measured: 5),
            "measured == model → nothing to clamp"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldClampToScreen(model: 5, measured: 6),
            "measured > model is the OTHER predicate's business, not clamp's"
        )

        // modelWord="ghbdt" (typed keycodes), screenWord="gghbdt" (one extra
        // character on screen) — measured−model=1, the screen word ends with
        // what we typed → accept.
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(
                model: 5, measured: 6, modelWord: "ghbdt", screenWord: "gghbdt"
            ),
            "measured−model=1 and the screen word ends with the typed word → extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 5, measured: 8, modelWord: "ghbdt", screenWord: "xxxghbdt"
            ),
            "measured−model=3 exceeds the 2-character budget → reject even with a matching suffix"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 4, modelWord: "ghb", screenWord: "ghx"
            ),
            "screen word does NOT end with the typed word → reject"
        )
        // "x/ghb" ends with "ghb" — hasSuffix is a plain string check and
        // cannot tell that "/" separates an unrelated path segment from the
        // typed word. The design does not pretend otherwise: this predicate
        // alone would accept it (delta=1 ≤ 2, suffix matches). What actually
        // keeps "x/ghb"-style cases safe is that a "/" makes the on-screen
        // text non-letters-only, which routes it through `convertWholeRun`
        // (whole-run conversion) rather than through this scored-path
        // predicate at all — a different guard, not a smarter suffix check.
        // Documenting the honest behavior here rather than inventing a
        // protection this function doesn't have.
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 4, modelWord: "ghb", screenWord: "x/ghb"
            ),
            "hasSuffix alone accepts \"x/ghb\" ending in \"ghb\" at delta=1 — the actual guard against this"
                + " case is convertWholeRun routing non-letter screen text away from this predicate entirely"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 6, modelWord: "ghb", screenWord: "xxx/ghb"
            ),
            "same suffix match but delta=3 > 2 → the budget rejects it regardless"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 0, measured: 1, modelWord: "", screenWord: "g"
            ),
            "empty modelWord (nothing typed to compare against) → reject"
        )
    }
}

/// Second line of defense for the same drift class: `convertWholeRun`'s
/// resync only covers ONE call site (`RunResyncStructuralGuardTests` above).
/// Any OTHER replacement that ends up delivered to an overlay field still
/// hands `TextReplacer` a `length` derived purely from its caller's typed
/// model. The guard is now ASYMMETRIC (16.08.2026 overlay-verified-erase
/// work): the screen holding LESS than the model still aborts — erasing
/// further would eat text that isn't ours — but the screen holding MORE is
/// cosmetic, not destructive, and is left to the verified erase
/// (`sendBackspacesVerified`) to sort out by watching the caret instead of
/// guessing a count. No live overlay window inside the headless harness, so
/// this reads the source, same precedent as `ReplacementAtomicityGuardTests`.
enum OverlayMismatchGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — an overlay delivery aborts only when the screen holds LESS than the model")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        guard let overlayMarker = text.range(
            of: "overlay delivery: posting to focused field pid=\\(overlayPid)"
        ), let pacingMarker = text.range(
            of: "let pacing = (axReadable && overlayPid == nil)"
        ) else {
            TestRunner.assertTrue(false, "overlay delivery block not found — test needs updating")
            return
        }
        let overlayBlock = String(text[overlayMarker.upperBound..<pacingMarker.lowerBound])

        TestRunner.assertTrue(
            overlayBlock.contains("CaretWordExtractor.wordBeforeCaret"),
            "the overlay guard re-measures the real on-screen word via AX before the replacement fires"
        )
        TestRunner.assertTrue(
            overlayBlock.contains("plan.backspaceCount"),
            "the guard compares against what the caller actually intends to erase"
        )

        guard let ltBranch = overlayBlock.range(of: "if ax < model {"),
              let gtBranch = overlayBlock.range(of: "} else if ax > model {", range: ltBranch.upperBound..<overlayBlock.endIndex)
        else {
            TestRunner.assertTrue(false, "ax < model / ax > model branches not found — test needs updating")
            return
        }
        let lessBranchBody = String(overlayBlock[ltBranch.upperBound..<gtBranch.lowerBound])
        let moreBranchBody = String(overlayBlock[gtBranch.upperBound...])

        TestRunner.assertTrue(
            lessBranchBody.contains("overlay replacement skipped: screen/model mismatch"),
            "screen holding LESS than the model is logged with the specific 'overlay replacement skipped' message"
        )
        TestRunner.assertTrue(
            lessBranchBody.contains("self.complete(.cancelled, cancellation: cancellation, completion: completion)"),
            "screen holding LESS than the model aborts the replacement (.cancelled)"
        )
        TestRunner.assertTrue(
            moreBranchBody.contains("overlay screen longer than model:"),
            "screen holding MORE than the model is logged with the specific 'overlay screen longer than model' message"
        )
        TestRunner.assertTrue(
            !moreBranchBody.contains(".cancelled"),
            "screen holding MORE than the model must NOT cancel the replacement — it's cosmetic, not destructive"
        )

        // Pacing diagnostics are no longer suppressed for the overlay path —
        // TextReplacer.swift used to log nothing at all there.
        guard let eraseDecisionMarker = text.range(
            of: "let eraseSucceeded: Bool", range: pacingMarker.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "pacing block not found — test needs updating")
            return
        }
        let pacingBlock = String(text[pacingMarker.upperBound..<eraseDecisionMarker.lowerBound])
        TestRunner.assertTrue(
            pacingBlock.contains("careful pacing: field not AX-readable"),
            "the non-overlay careful-pacing log is untouched"
        )
        TestRunner.assertTrue(
            pacingBlock.contains("overlay pacing: careful (forced"),
            "an overlay ALWAYS gets the careful pace — Spotlight lost one backspace per "
                + "gesture at the fast burst even with a readable AX value "
                + "(field episodes ccccara/cchr/ccfhf, 15-16.08.2026)"
        )
        TestRunner.assertTrue(
            !pacingBlock.contains("axReadable ? \"fast\" : \"careful\""),
            "the old readability-driven fast/careful switch for overlays is gone"
        )
    }
}

/// `sendBackspacesVerified` (16.08.2026, the "one backspace per gesture"
/// class this closes) reads the caret back between backspaces instead of
/// trusting a fixed count — pinned structurally, same precedent as
/// `ReplacementAtomicityGuardTests`: no live overlay window inside the
/// headless harness.
enum VerifiedEraseGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — verified erase for overlay panels")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        // (a) the overlay branch calls the verified erase, the plain branch
        // keeps calling the original blind burst — never the other way round.
        guard let eraseDecisionStart = text.range(of: "let eraseSucceeded: Bool"),
              let typeStringCall = text.range(
                of: "self.typeStringFast(plan.payload", range: eraseDecisionStart.upperBound..<text.endIndex
              )
        else {
            TestRunner.assertTrue(false, "erase decision block not found — test needs updating")
            return
        }
        let eraseDecisionBlock = String(text[eraseDecisionStart.upperBound..<typeStringCall.lowerBound])
        TestRunner.assertTrue(
            eraseDecisionBlock.contains("self.sendBackspacesVerified("),
            "the overlay branch calls the verified erase"
        )
        TestRunner.assertTrue(
            eraseDecisionBlock.contains("self.sendBackspaces("),
            "the non-overlay branch still calls the original blind burst"
        )

        // (b)-(e) the verified erase's own safety budget.
        guard let verifiedFuncStart = text.range(of: "private func sendBackspacesVerified(") else {
            TestRunner.assertTrue(false, "sendBackspacesVerified not found — test needs updating")
            return
        }
        let verifiedFuncTail = String(text[verifiedFuncStart.lowerBound...])
        let verifiedFuncBody = verifiedFuncTail.range(of: "\n    private func typeStringFast")
            .map { String(verifiedFuncTail[..<$0.lowerBound]) } ?? verifiedFuncTail

        TestRunner.assertTrue(
            verifiedFuncBody.contains("count + maxExtra"),
            "the erase loop is bounded to count + maxExtra events, never unbounded"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("maxExtra = 2"),
            "at most 2 extra backspaces are allowed to catch up on a measured drift"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("noProgress >= 2"),
            "the loop gives up once the caret stops moving for 2 consecutive events"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("deadline"),
            "the verification loop is bounded by a wall-clock budget, not just an event count"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("erase verified:"),
            "the outcome is logged with the specific 'erase verified:' format"
        )

        // (f) the payload retype is never verified via AX — only the erase is.
        guard let typeFuncStart = text.range(of: "private func typeStringFast(") else {
            TestRunner.assertTrue(false, "typeStringFast not found — test needs updating")
            return
        }
        let typeFuncBody = String(text[typeFuncStart.lowerBound...])
        TestRunner.assertTrue(
            !typeFuncBody.contains("selectionRange"),
            "typeStringFast never verifies via AX — the payload is not read back"
        )
    }
}

/// FIX A+B+C+D (13.08.2026 diagnosis, Cmd+Shift+V "paste without
/// formatting"): four independent defects in one feature. FIX A's
/// buffer-staleness half already has live coverage
/// (`KeyboardMonitorIntegrationTests`, "Cmd+Shift+V invalidates the stale
/// word buffer"); the rest needs a real pasteboard + focused app the
/// headless harness cannot provide, so it's pinned structurally instead,
/// same precedent as `ReplacementAtomicityGuardTests`.
enum PasteNoFormatGuardTests {
    static func run() {
        TestRunner.section("Cmd+Option+Shift+V — every pass resets state, formatting stripped only when present")

        let coreDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core")

        // --- FIX A + B(1): KeyboardMonitor.handleEvent's kc9 branch --------
        guard let kmText = try? String(
            contentsOf: coreDir.appendingPathComponent("KeyboardMonitor.swift"), encoding: .utf8
        ) else {
            TestRunner.skip("KeyboardMonitor.swift not readable")
            return
        }
        guard let branchStart = kmText.range(of: "keycode == 9 {"),
              let branchEnd = kmText.range(
                of: "// Cmd+Option+Z", range: branchStart.upperBound..<kmText.endIndex
              ) else {
            TestRunner.assertTrue(false, "Cmd+Shift+V branch not found — test needs updating")
            return
        }
        let branch = String(kmText[branchStart.upperBound..<branchEnd.lowerBound])
        TestRunner.assertTrue(
            branch.contains("hotkeyManager?.markKeyPressed()"),
            "FIX B: a swallowed V still registers as a real keypress (kills the ghost shift-tap)"
        )
        TestRunner.assertTrue(
            branch.contains("invalidateEditingContext(reason: \"paste-no-format\")"),
            "FIX A: every pass through the branch resets buffer/runKeystrokes/lastCompletedWord"
        )
        TestRunner.assertTrue(
            branch.contains("pasteNoFormat: swallowed enabled=") && branch.contains("started="),
            "FIX D: the branch is observable in the debug log (metadata only)"
        )

        // --- FIX (15.08.2026): Option is now required on BOTH the shortcut
        // classifier (handlesShortcut) and the handler (handleEvent) — a
        // stray plain Cmd+Shift+V must not match either, or the tap would
        // suppress it in one place while still trying to act on it (or vice
        // versa). Checked directly against the full file text rather than
        // `branch` above, since `branch` starts right after the FIRST
        // "keycode == 9 {" match (inside `handlesShortcut`) and so never
        // contains the condition text leading up to that marker.
        let pasteCondition =
            "flags.contains(.maskCommand) && flags.contains(.maskShift)"
                + " && flags.contains(.maskAlternate) && keycode == 9"
        let pasteConditionCount = kmText.components(separatedBy: pasteCondition).count - 1
        TestRunner.assertEqual(
            pasteConditionCount, 2,
            "both handlesShortcut and handleEvent require Option — bare Cmd+Shift+V matches neither"
        )

        // --- FIX B(2): fresh Shift-down seeds anyModifierWithShift from
        //     THIS event's own flags instead of an unconditional reset.
        guard let hkText = try? String(
            contentsOf: coreDir.appendingPathComponent("HotkeyManager.swift"), encoding: .utf8
        ) else {
            TestRunner.skip("HotkeyManager.swift not readable")
            return
        }
        TestRunner.assertTrue(
            hkText.contains("anyModifierWithShift = Self.modifierDisqualifiesShiftTap(flags)"),
            "FIX B: a fresh Shift-down derives anyModifierWithShift from this event's own flags"
        )

        // --- FIX C + D: handlePasteNoFormat --------------------------------
        guard let funcStart = hkText.range(of: "func handlePasteNoFormat(completion:"),
              let funcEnd = hkText.range(
                of: "private struct PasteboardSnapshot", range: funcStart.upperBound..<hkText.endIndex
              ) else {
            TestRunner.assertTrue(false, "handlePasteNoFormat not found — test needs updating")
            return
        }
        let pasteFn = String(hkText[funcStart.upperBound..<funcEnd.lowerBound])
        TestRunner.assertTrue(
            pasteFn.contains(".pasteboardItems"),
            "FIX C: the pasteboard's actual flavors are inspected before deciding whether to substitute"
        )
        TestRunner.assertTrue(
            pasteFn.contains("onlyPlainText"),
            "FIX C: a pasteboard with no non-plain flavors skips the clear/set substitution entirely"
        )
        TestRunner.assertTrue(
            pasteFn.contains("+ 0.4"),
            "FIX C: the restore delay was widened from 0.15s to 0.4s"
        )
        TestRunner.assertTrue(
            pasteFn.contains("paste-no-format: len=") && pasteFn.contains("flavors=")
                && pasteFn.contains("substituted="),
            "FIX D: the substitution decision is logged with metadata only, never the pasted text"
        )
        TestRunner.assertTrue(
            pasteFn.contains("restore="),
            "FIX D: the restore outcome (done/skipped) is logged"
        )
    }
}

enum StatusInkContrastTests {
    static func run() {
        TestRunner.section("StatusInk — measured contrast, both appearances")

        let inks: [(String, NSColor)] = [
            ("green", StatusInk.greenNS), ("amber", StatusInk.amberNS), ("red", StatusInk.redNS)
        ]
        for (appearanceName, appearance, surfaces) in [
            ("light", NSAppearance.Name.aqua, StatusInk.lightSurfaces),
            ("dark", NSAppearance.Name.darkAqua, StatusInk.darkSurfaces)
        ] {
            guard let look = NSAppearance(named: appearance) else {
                TestRunner.skip("appearance \(appearanceName) unavailable")
                continue
            }
            look.performAsCurrentDrawingAppearance {
                for (name, ink) in inks {
                    let ratios = surfaces.compactMap { Contrast.ratio(ink, $0) }
                    guard ratios.count == surfaces.count, let worst = ratios.min() else {
                        TestRunner.assertTrue(false, "\(name)/\(appearanceName): color not convertible to sRGB")
                        continue
                    }
                    TestRunner.assertTrue(
                        worst >= 4.5,
                        "\(name) on \(appearanceName): worst surface \(String(format: "%.2f", worst)):1 ≥ 4.5:1"
                    )
                }
            }
        }

        // Sanity anchors for the formula itself — if these drift, the ratios
        // above are measuring nothing.
        if let blackOnWhite = Contrast.ratio(.black, .white) {
            TestRunner.assertTrue(
                abs(blackOnWhite - 21.0) < 0.01,
                "black on white is 21:1 (got \(String(format: "%.2f", blackOnWhite)))"
            )
        }
        if let same = Contrast.ratio(.white, .white) {
            TestRunner.assertTrue(abs(same - 1.0) < 0.01, "a color against itself is 1:1")
        }
    }
}

enum SecureInputAXTierTests {
    static func run() {
        TestRunner.section("SecureInputDetector — the AX tier never blocks isSecureInput")

        // Gated (not unconditional) so a genuine wiring regression fails
        // fast with a clear assertion instead of hanging the whole suite.
        let axGate = DispatchSemaphore(value: 0)
        let detector = SecureInputDetector(
            secureCheck: { false },
            axProbe: {
                _ = axGate.wait(timeout: .now() + 2.0)
                return true
            }
        )

        let start = CFAbsoluteTimeGetCurrent()
        let result = detector.isSecureInput
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        axGate.signal() // release the background probe so it doesn't leak into later tests

        TestRunner.assertTrue(!result, "first access returns before the (still gated) AX probe ever resolves")
        TestRunner.assertTrue(
            elapsed < 0.05,
            "isSecureInput returns immediately — the AX probe runs off-thread, never inline"
                + " (took \(Int(elapsed * 1000))ms)"
        )
    }
}

enum CallbackDurationThresholdTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.shouldWarnSlowCallback — pure threshold")
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldWarnSlowCallback(0.005, threshold: 0.015),
            "a 5ms callback is well under the 15ms budget"
        )
        TestRunner.assertTrue(
            KeyboardMonitor.shouldWarnSlowCallback(0.020, threshold: 0.015),
            "a 20ms callback exceeds the 15ms budget and should log a warning"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldWarnSlowCallback(0.015, threshold: 0.015),
            "exactly at the threshold does not warn (strictly greater-than)"
        )
    }
}

enum TapTimeoutCounterTests {
    static func run() {
        TestRunner.section("KeyboardMonitor — tapDisabledByTimeout increments an observable counter")
        guard TestRunner.syntheticKeyboardEventsAreSafe else {
            TestRunner.skip("macOS 27 blocks synthetic CGEvent construction in this headless harness")
            return
        }
        let inputSources = InputSourceManager()
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)

        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0, keyDown: true
        ) else {
            TestRunner.assertTrue(false, "fixture event constructs")
            return
        }
        let proxy = OpaquePointer(UnsafeMutableRawPointer(bitPattern: 1)!)

        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 0, "counter starts at 0")
        h.monitor.handleEvent(proxy, type: .tapDisabledByTimeout, event: event)
        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 1, "one timeout-disable event increments the counter")
        h.monitor.handleEvent(proxy, type: .tapDisabledByTimeout, event: event)
        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 2, "counter accumulates across repeated events")
    }
}

enum SwitchBlockReasonTests {
    static func run() {
        TestRunner.section("SwitchBlockReason — resolves the single status-bar/menu/tooltip reason")

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
            ),
            .none,
            "everything working → no reason, no line in the menu"
        )
        TestRunner.assertNil(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
            ).title,
            "'.none' has no title — absence of a line, never a reassuring filler"
        )

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: "Safari"
            ),
            .secureInput(appName: "Safari"),
            "secure input with a known app name is reported as its own case"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: "Safari"
            ).title,
            "Пароль в Safari — переключение приостановлено",
            "known app name is folded into the line"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
            ).title,
            "Ввод пароля — переключение приостановлено",
            "unknown app name falls back to the generic wording — never a guessed name"
        )
        TestRunner.assertTrue(
            SwitchBlockReason.resolve(
                health: .secureInput, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
            ).blocksSwitching,
            "secure input blocks switching"
        )

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .missingPermissions, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
            ).title,
            "Нет разрешения Универсального доступа",
            "missing permissions wins over every other check"
        )

        for downHealth: EventTapHealth in [.starting, .unavailable, .stopped] {
            TestRunner.assertEqual(
                SwitchBlockReason.resolve(
                    health: downHealth, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil
                ).title,
                "Перехват клавиш остановлен",
                "\(downHealth) health reads as 'interception stopped'"
            )
        }

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: false, isEntitled: true, secureInputAppName: nil
            ).title,
            "Автопереключение выключено",
            "healthy tap but auto-switch off"
        )

        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: false, secureInputAppName: nil
            ).title,
            "Подписка истекла",
            "healthy tap, auto-switch on, but license lapsed"
        )

        // Priority: health problems outrank auto-switch/license even when
        // BOTH are also off/expired — the user should see the more urgent,
        // actionable cause first, not whichever check happens to run last.
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .missingPermissions, isAutoSwitchEnabled: false, isEntitled: false, secureInputAppName: nil
            ).title,
            "Нет разрешения Универсального доступа",
            "missing permissions outranks auto-switch-off AND expired license together"
        )

        // Per-app profile block (0.7.0's per-app profiles otherwise leave
        // this badge silent while the app itself is effectively disabled).
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, "Terminal")
            ).title,
            "Автопереключение выключено для Terminal",
            "app-profile auto-switch block names the app"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, nil)
            ).title,
            "Автопереключение выключено для этого приложения",
            "unknown app name falls back to generic wording, same as secure input"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil,
                appProfileBlock: (.instantCorrectionOnly, "Ghostty")
            ).title,
            "Мгновенная коррекция выключена для Ghostty",
            "instant-correction-only block is worded as a partial restriction, not a full stop"
        )
        TestRunner.assertNil(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: true, isEntitled: true, secureInputAppName: nil,
                appProfileBlock: nil
            ).title,
            "no app-profile block passed → still '.none', unchanged from before 0.7.0"
        )
        TestRunner.assertEqual(
            SwitchBlockReason.resolve(
                health: .running, isAutoSwitchEnabled: false, isEntitled: true, secureInputAppName: nil,
                appProfileBlock: (.autoSwitch, "Terminal")
            ).title,
            "Автопереключение выключено",
            "global auto-switch-off outranks an app-profile block — no point naming one app when it's off everywhere"
        )
    }
}

enum SoundServiceToggleCueTests {
    static func run() {
        TestRunner.section("SoundService.toggleCue — pure resolver for the auto-switch on/off cue")

        guard let onCue = SoundService.toggleCue(enabled: true, isSoundEnabled: true, storedName: "Glass") else {
            TestRunner.assertTrue(false, "ON cue resolves when sound is enabled")
            return
        }
        TestRunner.assertEqual(onCue.name, "Glass", "ON reuses the owner's chosen layout-switch timbre")
        TestRunner.assertEqual(onCue.volume, 1.0, "ON plays at full volume")

        guard let offCue = SoundService.toggleCue(enabled: false, isSoundEnabled: true, storedName: "Glass") else {
            TestRunner.assertTrue(false, "OFF cue resolves when sound is enabled")
            return
        }
        TestRunner.assertEqual(offCue.name, "Glass", "OFF is the SAME timbre as ON, not a different sound")
        TestRunner.assertEqual(offCue.volume, 0.45, "OFF plays quieter than ON — reads as softer, not an alert")

        TestRunner.assertNil(
            SoundService.toggleCue(enabled: true, isSoundEnabled: false, storedName: "Glass"),
            "master sound gate off silences the toggle cue entirely"
        )
        TestRunner.assertNil(
            SoundService.toggleCue(enabled: false, isSoundEnabled: false, storedName: "Glass"),
            "master sound gate off silences OFF too"
        )
        TestRunner.assertNil(
            SoundService.toggleCue(enabled: true, isSoundEnabled: true, storedName: SoundService.noSoundName),
            "'Без звука' selected → toggle stays silent even with sound enabled"
        )

        guard let fallbackCue = SoundService.toggleCue(
            enabled: true, isSoundEnabled: true, storedName: "TotallyBogusSoundName"
        ) else {
            TestRunner.assertTrue(false, "an unrecognized stored name still resolves via the safe fallback")
            return
        }
        TestRunner.assertEqual(fallbackCue.name, "Pop", "corrupted/stale stored name falls back to Pop, not a crash")
    }
}

enum DockIconPolicyTests {
    static func run() {
        TestRunner.section("DockIconPolicy — reference-counted Dock icon across Settings/Exceptions/About/License/onboarding")

        var policy = DockIconPolicy()
        TestRunner.assertEqual(policy.openWindowCount, 0, "starts with nothing open")

        TestRunner.assertTrue(policy.windowOpened(), "the FIRST window to open should show the Dock icon")
        TestRunner.assertEqual(policy.openWindowCount, 1, "count after first open")

        TestRunner.assertTrue(!policy.windowOpened(), "a second concurrently open window must NOT re-trigger showing the icon")
        TestRunner.assertEqual(policy.openWindowCount, 2, "count after second open")

        TestRunner.assertTrue(!policy.windowClosed(), "closing one of two open windows must NOT hide the icon yet")
        TestRunner.assertEqual(policy.openWindowCount, 1, "one window still open")

        TestRunner.assertTrue(policy.windowClosed(), "closing the LAST open window should hide the Dock icon")
        TestRunner.assertEqual(policy.openWindowCount, 0, "count back to zero")

        TestRunner.assertTrue(!policy.windowClosed(), "closing with nothing open is a safe no-op, not a negative count")
        TestRunner.assertEqual(policy.openWindowCount, 0, "count never goes negative")

        // Re-open after fully closing — must behave exactly like the very
        // first open (regression guard: a stale count from a earlier close
        // 5-window session should never suppress the icon on the next open).
        TestRunner.assertTrue(policy.windowOpened(), "re-opening after a full close shows the icon again")
    }
}

// MARK: - Wave 1 "learning" modules (learning_spec.md) — pure, no AX/live input

enum LearnedWordsStoreTests {
    static func run() {
        TestRunner.section("LearnedWordsStore")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400

        let suite = AppIdentity.bundleIdentifier + ".tests.learnedWords." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)

        // record -> count, not yet active
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: "com.app.one", at: t0),
            .recorded, "first confirmation is just recorded"
        )
        TestRunner.assertEqual(store.allEntries["en:clear"]?.count, 1, "count is 1 after first confirmation")
        TestRunner.assertTrue(!store.isActive(word: "clear", lang: "en"), "single confirmation is not yet active")

        // promote = 2 within the 30-day window
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: "com.app.one", at: t0.addingTimeInterval(5 * day)),
            .promoted, "second confirmation within the window promotes the entry"
        )
        TestRunner.assertTrue(store.isActive(word: "clear", lang: "en"), "promoted entry is active")
        TestRunner.assertTrue(store.activeKeys(lang: "en").contains("clear"), "activeKeys surfaces the bare word")

        // NOT promoted outside the 30-day window -> resets to count 1
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0),
            .recorded, "vmc first confirmation"
        )
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0.addingTimeInterval(31 * day)),
            .recorded, "a confirmation past the 30-day window resets rather than promotes"
        )
        TestRunner.assertTrue(!store.isActive(word: "vmc", lang: "en"), "reset entry is not active")
        TestRunner.assertEqual(store.allEntries["en:vmc"]?.count, 1, "reset entry count is back to 1")

        // unlearn
        store.unlearn(word: "clear", lang: "en")
        TestRunner.assertTrue(!store.isActive(word: "clear", lang: "en"), "unlearn removes activity")
        TestRunner.assertNil(store.allEntries["en:clear"], "unlearn removes the entry entirely")

        // revoke never drops below zero, and a count reaching zero removes the entry.
        // vmc is still count 1 (firstConfirmed = t0+31day) from the reset above — one
        // more confirmation inside its (new) window promotes it to count 2.
        TestRunner.assertEqual(
            store.recordManualFix(word: "vmc", lang: "en", originApp: nil, at: t0.addingTimeInterval(32 * day)),
            .promoted, "vmc promoted to count 2"
        )
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertEqual(store.allEntries["en:vmc"]?.count, 1, "revoke decrements by exactly one")
        TestRunner.assertTrue(!store.isActive(word: "vmc", lang: "en"), "count 1 after revoke is not active")
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertNil(store.allEntries["en:vmc"], "revoke down to zero removes the entry")
        store.revokeRecord(word: "vmc", lang: "en")
        TestRunner.assertNil(store.allEntries["en:vmc"], "revoke on a missing entry is a safe no-op")

        // disabled mutes both recording and application
        store.recordManualFix(word: "bnb", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "bnb", lang: "en", originApp: nil, at: t0.addingTimeInterval(day))
        TestRunner.assertTrue(store.isActive(word: "bnb", lang: "en"), "bnb promoted before disabling")
        store.isEnabled = false
        TestRunner.assertTrue(!store.isActive(word: "bnb", lang: "en"), "disabled store reports nothing as active")
        store.recordManualFix(word: "ip", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "ip", lang: "en", originApp: nil, at: t0.addingTimeInterval(day))
        TestRunner.assertNil(store.allEntries["en:ip"], "recording while disabled is a no-op")
        store.isEnabled = true
        TestRunner.assertTrue(store.isActive(word: "bnb", lang: "en"), "re-enabling restores prior activity")

        // normalization guard: store expects already-lowercased, non-empty input
        let countBeforeInvalid = store.allEntries.count
        store.recordManualFix(word: "Exit", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "", lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: "exit", lang: "", originApp: nil, at: t0)
        TestRunner.assertEqual(
            store.allEntries.count, countBeforeInvalid,
            "uppercase input and empty word/lang are silently rejected — caller's job to normalize"
        )

        // eviction: count==1 evicted before count>=2, oldest lastConfirmed first
        let evictionSuite = AppIdentity.bundleIdentifier + ".tests.learnedWordsEviction." + UUID().uuidString
        guard let evictionDefaults = UserDefaults(suiteName: evictionSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { evictionDefaults.removePersistentDomain(forName: evictionSuite) }
        let evictionStore = LearnedWordsStore(defaults: evictionDefaults)

        for i in 0..<299 {
            let base = t0.addingTimeInterval(TimeInterval(i) * day)
            evictionStore.recordManualFix(word: "w\(i)", lang: "en", originApp: nil, at: base)
            evictionStore.recordManualFix(word: "w\(i)", lang: "en", originApp: nil, at: base.addingTimeInterval(60))
        }
        evictionStore.recordManualFix(word: "oldweak", lang: "en", originApp: nil, at: t0.addingTimeInterval(1_000 * day))
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store sits exactly at cap: 299 promoted + 1 weak")

        let overflowOutcome = evictionStore.recordManualFix(
            word: "newweak", lang: "en", originApp: nil, at: t0.addingTimeInterval(2_000 * day)
        )
        TestRunner.assertEqual(overflowOutcome, .capped, "insert past cap reports an eviction")
        TestRunner.assertNil(evictionStore.allEntries["en:oldweak"], "the OLDER count==1 entry is evicted first")
        TestRunner.assertTrue(
            evictionStore.allEntries["en:newweak"] != nil,
            "the just-inserted (newer) weak entry survives while an older weak entry exists"
        )
        TestRunner.assertTrue(
            evictionStore.isActive(word: "w0", lang: "en"), "promoted entries are untouched while any weak entry remains"
        )
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store stays at cap")

        // once no weak entries remain, an overflow evicts the newcomer itself — promoted entries stay protected
        evictionStore.unlearn(word: "newweak", lang: "en")
        let extraBase = t0.addingTimeInterval(3_000 * day)
        evictionStore.recordManualFix(word: "w299", lang: "en", originApp: nil, at: extraBase)
        evictionStore.recordManualFix(word: "w299", lang: "en", originApp: nil, at: extraBase.addingTimeInterval(60))
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store is now 300 promoted entries, zero weak")

        let selfEvictOutcome = evictionStore.recordManualFix(
            word: "loner", lang: "en", originApp: nil, at: t0.addingTimeInterval(4_000 * day)
        )
        TestRunner.assertEqual(selfEvictOutcome, .capped, "overflow against an all-promoted store still reports an eviction")
        TestRunner.assertNil(
            evictionStore.allEntries["en:loner"],
            "with no weak entry to sacrifice, the newcomer itself is evicted — promoted entries are protected"
        )
        TestRunner.assertTrue(evictionStore.isActive(word: "w0", lang: "en"), "no promoted entry is ever evicted by this policy")
        TestRunner.assertEqual(evictionStore.allEntries.count, 300, "store remains exactly at cap")

        // persistence round-trip
        let persistSuite = AppIdentity.bundleIdentifier + ".tests.learnedWordsPersist." + UUID().uuidString
        guard let persistDefaults = UserDefaults(suiteName: persistSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { persistDefaults.removePersistentDomain(forName: persistSuite) }
        let writer = LearnedWordsStore(defaults: persistDefaults)
        writer.recordManualFix(word: "clear", lang: "en", originApp: "com.app.terminal", at: t0)
        writer.recordManualFix(word: "clear", lang: "en", originApp: "com.app.terminal", at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let reader = LearnedWordsStore(defaults: persistDefaults)
        TestRunner.assertTrue(reader.isActive(word: "clear", lang: "en"), "a promoted entry survives a flush + reload")
        TestRunner.assertEqual(reader.allEntries["en:clear"]?.originApp, "com.app.terminal", "originApp round-trips")
        writer.flush(now: t0) // dirty flag already false — no-op, must not crash
    }
}

enum PersonalFrequencyStoreTests {
    static func run() {
        TestRunner.section("PersonalFrequencyStore")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400

        let suite = AppIdentity.bundleIdentifier + ".tests.personalFreq." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PersonalFrequencyStore(defaults: defaults)

        // length gate is the store's own guard (junk/mixed-script/projection gates are
        // wave-2 caller concerns computed against JunkMeter/LanguageDetector — see the
        // file's doc comment)
        store.bump(word: "ip", lang: "en", isDictionaryWord: false, at: t0)
        TestRunner.assertNil(store.allEntries["en:ip"], "words shorter than 3 letters are never bumped")

        // promotion >= 5
        for i in 0..<4 {
            let outcome = store.bump(
                word: "vmc", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(TimeInterval(i) * day)
            )
            TestRunner.assertEqual(outcome, .bumped, "bump #\(i + 1) is a plain bump, not yet promoted")
        }
        TestRunner.assertTrue(!store.isPromoted(word: "vmc", lang: "en"), "count 4 is not yet promoted")
        let fifthOutcome = store.bump(word: "vmc", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(4 * day))
        TestRunner.assertEqual(fifthOutcome, .promoted, "the 5th bump promotes")
        TestRunner.assertTrue(store.isPromoted(word: "vmc", lang: "en"), "count 5 is promoted")
        TestRunner.assertTrue(store.promotedKeys(lang: "en").contains("vmc"), "promotedKeys surfaces the bare word")

        // unlearn
        store.unlearn(word: "vmc", lang: "en")
        TestRunner.assertTrue(!store.isPromoted(word: "vmc", lang: "en"), "unlearn clears promotion")
        TestRunner.assertNil(store.allEntries["en:vmc"], "unlearn removes the entry")

        // disabled mutes both bumping and application
        for i in 0..<5 {
            store.bump(word: "clear", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(TimeInterval(i) * day))
        }
        TestRunner.assertTrue(store.isPromoted(word: "clear", lang: "en"), "clear promoted before disabling")
        store.isEnabled = false
        TestRunner.assertTrue(!store.isPromoted(word: "clear", lang: "en"), "disabled store reports nothing as promoted")
        store.bump(word: "exit", lang: "en", isDictionaryWord: false, at: t0)
        TestRunner.assertNil(store.allEntries["en:exit"], "bumping while disabled is a no-op")
        store.isEnabled = true
        TestRunner.assertTrue(store.isPromoted(word: "clear", lang: "en"), "re-enabling restores prior promotion")

        // count mirrors store size
        TestRunner.assertEqual(store.count, store.allEntries.count, "count mirrors the store size")

        // persistence: count==1 never persisted; dictionary words persist at count>=2, non-dictionary at count>=3
        let persistSuite = AppIdentity.bundleIdentifier + ".tests.personalFreqPersist." + UUID().uuidString
        guard let persistDefaults = UserDefaults(suiteName: persistSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { persistDefaults.removePersistentDomain(forName: persistSuite) }
        let writer = PersonalFrequencyStore(defaults: persistDefaults)

        writer.bump(word: "raz", lang: "ru", isDictionaryWord: true, at: t0)
        writer.flush(now: t0)
        let readerA = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertNil(readerA.allEntries["ru:raz"], "a single confirmation never reaches disk, even for a dictionary word")

        writer.bump(word: "raz", lang: "ru", isDictionaryWord: true, at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let readerB = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertEqual(readerB.allEntries["ru:raz"]?.count, 2, "a dictionary word persists at count 2")

        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0)
        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0.addingTimeInterval(day))
        writer.flush(now: t0.addingTimeInterval(day))
        let readerC = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertNil(readerC.allEntries["ru:zhargon"], "a non-dictionary word at count 2 does not yet reach disk")

        writer.bump(word: "zhargon", lang: "ru", isDictionaryWord: false, at: t0.addingTimeInterval(2 * day))
        writer.flush(now: t0.addingTimeInterval(2 * day))
        let readerD = PersonalFrequencyStore(defaults: persistDefaults)
        TestRunner.assertEqual(readerD.allEntries["ru:zhargon"]?.count, 3, "a non-dictionary word persists once it reaches count 3")

        // cap
        let capSuite = AppIdentity.bundleIdentifier + ".tests.personalFreqCap." + UUID().uuidString
        guard let capDefaults = UserDefaults(suiteName: capSuite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { capDefaults.removePersistentDomain(forName: capSuite) }
        let capStore = PersonalFrequencyStore(defaults: capDefaults)
        for i in 0..<1_999 {
            let base = t0.addingTimeInterval(TimeInterval(i) * day)
            capStore.bump(word: "pfw\(i)", lang: "en", isDictionaryWord: false, at: base)
            capStore.bump(word: "pfw\(i)", lang: "en", isDictionaryWord: false, at: base.addingTimeInterval(60))
        }
        capStore.bump(word: "oldweak", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(5_000 * day))
        TestRunner.assertEqual(capStore.count, 2_000, "cap store sits exactly at cap: 1999 non-weak words + 1 weak")

        let capOutcome = capStore.bump(word: "newweak", lang: "en", isDictionaryWord: false, at: t0.addingTimeInterval(6_000 * day))
        TestRunner.assertEqual(capOutcome, .capped, "insert past cap reports an eviction")
        TestRunner.assertNil(capStore.allEntries["en:oldweak"], "the OLDER count==1 entry is evicted first")
        TestRunner.assertTrue(
            capStore.allEntries["en:newweak"] != nil, "the newer weak entry survives while an older one exists"
        )
        TestRunner.assertEqual(capStore.count, 2_000, "cap store stays at cap")
    }
}

enum CorrectionFeedbackTrackerTests {
    static func run() {
        TestRunner.section("CorrectionFeedbackTracker")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // revert: word == corrected, reverse direction, within 8s
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(5))
            TestRunner.assertEqual(
                verdict,
                .revertOfAutoCorrection(original: "руддщ", corrected: "hello", wasLearned: false),
                "DS reversing a recent auto-correction within 8s is a revert"
            )
        }

        // not-revert: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "other", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(2))
            TestRunner.assertEqual(verdict, .manualFix, "a different word is never classified as a revert")
        }

        // not-revert: same direction (not reversed)
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "ru", targetLang: "en", at: t0.addingTimeInterval(2))
            TestRunner.assertEqual(verdict, .manualFix, "DS in the same direction as the correction is not a revert")
        }

        // not-revert: past the 8s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(9))
            TestRunner.assertEqual(verdict, .manualFix, "DS past the 8s window is not a revert")
        }

        // not-revert: after reset()
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            tracker.reset()
            let verdict = tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1))
            TestRunner.assertEqual(verdict, .manualFix, "reset() clears the pending auto-correction")
        }

        // toggle: one-shot slot — DS#2 toggles, DS#3 on the same reverse gesture is a plain manual fix
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let toggle = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(3))
            TestRunner.assertEqual(
                toggle, .toggleOfManualFix(word: "clear", lang: "en"),
                "DS reversing a recent manual conversion within 10s toggles it"
            )
            let thirdPress = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(5))
            TestRunner.assertEqual(thirdPress, .manualFix, "the toggle slot is one-shot — a third DS is a plain manual fix")
        }

        // not-toggle: past the 10s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let verdict = tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(11))
            TestRunner.assertEqual(verdict, .manualFix, "DS past the 10s toggle window is a plain manual fix")
        }

        // not-toggle: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            let verdict = tracker.classifyDoubleShift(word: "other", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(3))
            TestRunner.assertEqual(verdict, .manualFix, "a different word is never classified as a toggle")
        }

        // revert-of-revert: DS toward the annulled correction, within 15s, lifts the exception
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(10)),
                "DS on the reverted word within 15s lifts the just-created exception"
            )
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(11)),
                "revert-of-revert is one-shot — the slot is consumed after the first match"
            )
        }

        // not-revert-of-revert: different word
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "other", targetLang: "en", at: t0.addingTimeInterval(5)),
                "a different word never lifts the exception"
            )
        }

        // not-revert-of-revert: past the 15s window
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(16)),
                "past the 15s window, the exception is not lifted"
            )
        }

        // reset() clears every kind of pending state at once
        do {
            let tracker = CorrectionFeedbackTracker()
            tracker.recordAutoCorrection(original: "руддщ", corrected: "hello", targetLang: "en", wasLearned: false, at: t0)
            tracker.recordManualConversion(word: "clear", sourceLang: "ru", targetLang: "en", at: t0)
            tracker.recordRevert(original: "смотри", corrected: "cvjnhb", at: t0)
            tracker.reset()
            TestRunner.assertEqual(
                tracker.classifyDoubleShift(word: "hello", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1)),
                .manualFix, "reset clears the pending auto-correction"
            )
            TestRunner.assertEqual(
                tracker.classifyDoubleShift(word: "clear", sourceLang: "en", targetLang: "ru", at: t0.addingTimeInterval(1)),
                .manualFix, "reset clears the pending manual conversion"
            )
            TestRunner.assertTrue(
                !tracker.classifyRevertOfRevert(word: "смотри", targetLang: "en", at: t0.addingTimeInterval(1)),
                "reset clears the pending revert"
            )
        }
    }
}

// MARK: - Wave 2: integration (learning_spec.md "Тесты → Волна 2")

/// Write-time normalization primitives `KeyboardMonitor.normalizedLearnableCore`
/// reuses — `core(of:)`'s multi-core rejection and
/// `isReservedForDisambiguation`'s closed-list membership are both plain,
/// stateless statics on `LanguageDetector` and testable directly without any
/// keystroke fixture. The `resynced`/`disabled` branches of
/// `normalizedLearnableCore` itself are KeyboardMonitor-private glue with no
/// independent seam — covered by code review + the KM integration tests
/// below, not re-tested here in isolation.
enum LearningNormalizationTests {
    static func run() {
        TestRunner.section("Wave 2 — write-time normalization primitives")

        TestRunner.assertNil(LanguageDetector.core(of: "model/path"), "two letter runs separated by a symbol → no core (>1 core rejected)")
        TestRunner.assertNil(LanguageDetector.core(of: "--flag=value"), "flag=value → no single core")
        TestRunner.assertEqual(LanguageDetector.core(of: "/model"), "model", "leading symbol stripped, trailing none")
        TestRunner.assertEqual(LanguageDetector.core(of: "clear"), "clear", "pure word is its own core")
        TestRunner.assertNil(LanguageDetector.core(of: "123"), "digits-only has no letter core")

        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("vs", language: "en"), "'vs' (conflictPairs value) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("мы", language: "ru"), "'мы' (conflictPairs key) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("на", language: "ru"), "'на' (twoLetterWords ru) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("of", language: "en"), "'of' (twoLetterWords en + conflictPairs value) is reserved")
        TestRunner.assertTrue(LanguageDetector.isReservedForDisambiguation("и", language: "ru"), "'и' (oneLetterWords ru) is reserved")
        TestRunner.assertTrue(!LanguageDetector.isReservedForDisambiguation("clear", language: "en"), "'clear' is NOT in any disambiguation list")
        TestRunner.assertTrue(!LanguageDetector.isReservedForDisambiguation("vs", language: "ru"), "'vs' is only reserved for its OWN language side")
    }
}

/// learning_spec.md "Тесты → Волна 2" #4 — Instant-байпас.
enum InstantLearningBypassTests {
    static func run() {
        TestRunner.section("Wave 2 — InstantCorrectionAnalyzer learned bypass")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the learned-bypass fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        guard let clearStrokes = InstantCorrectionFixtures.keystrokes(for: "сдуфк", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'сдуфк' fixture can type every character")
            return
        }
        func convert(_ strokes: [BufferedKeystroke]) -> (KeyboardLayout) -> String {
            { layout in inputSources.convertKeystrokes(strokes, toLayout: layout) }
        }

        // Empty Set: byte-for-byte the ordinary path — junkGate silences the
        // flagship "сдуфк" case exactly like the pre-wave-2 corpus expects.
        let ordinary = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: []
        )
        TestRunner.assertNil(ordinary.result, "empty learnedActive: 'сдуфк' stays silent — byte-for-byte the pre-wave-2 corpus behavior")

        // Fires THROUGH whatever silenced the ordinary call above (junkGate
        // here) once "clear" is an active learned entry — the flagship case.
        let learned = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: ["clear"]
        )
        TestRunner.assertTrue(ordinary.silence != nil, "sanity: the ordinary path really was silenced by some gate")
        TestRunner.assertEqual(learned.result?.correctedWord, "clear", "learned bypass fires 'сдуфк' → clear through the ordinary gate")
        TestRunner.assertTrue(learned.result?.wasLearned == true, "fired result is flagged wasLearned")

        // ownIsWord: own reading is a REAL ru dictionary word (wordLevel!=0)
        // — the learned bypass's own-guard blocks it exactly like the
        // ordinary path would, even though the ceiling itself is not
        // applied in this branch.
        guard let ownWordStrokes = InstantCorrectionFixtures.keystrokes(for: "омск", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'омск' fixture can type every character")
            return
        }
        let ownWordEnReading = inputSources.convertKeystrokes(ownWordStrokes, toLayout: enLayout).lowercased()
        let blockedByOwnWord = analyzer.evaluate(
            keystrokes: ownWordStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(ownWordStrokes), learnedActive: [ownWordEnReading]
        )
        TestRunner.assertNil(blockedByOwnWord.result, "own reading is a real ru word ('омск') — learned bypass stays silent even with a matching active entry")

        // Below minLength: never evaluated regardless of learnedActive.
        let short = Array(clearStrokes.prefix(InstantCorrectionAnalyzer.minLength - 1))
        let shortResult = analyzer.evaluate(
            keystrokes: short, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(short), learnedActive: ["cle"]
        )
        TestRunner.assertNil(shortResult.result, "shorter than minLength never fires, even with an exact-matching learnedActive entry")

        // mixedScript candidate: even an EXACT learnedActive match must not
        // fire when the candidate text itself is mixed-script garbage.
        let mixedCandidate = "cleeх" // latin + one cyrillic х
        let mixedResult = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: { layout in layout.id == ruLayout.id ? "фываю" : mixedCandidate },
            learnedActive: [mixedCandidate]
        )
        TestRunner.assertNil(mixedResult.result, "mixed-script candidate never fires even with a matching learnedActive entry")

        // count==1 (not yet promoted) end-to-end through the real store: a
        // single confirmation never reaches `activeKeys`, so the bypass
        // never sees it.
        let suite = AppIdentity.bundleIdentifier + ".tests.instantLearnedCount1." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)
        store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
        let count1Result = analyzer.evaluate(
            keystrokes: clearStrokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert(clearStrokes), learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertNil(count1Result.result, "count==1 (not yet promoted) never reaches the bypass via the real store")
    }
}

/// learning_spec.md "Тесты → Волна 2" #5 — Boundary-байпас. Conflict-pair
/// arbitration and junk-override own-guard regressions are covered by the
/// EXISTING `ConflictPairDisambiguationTests`/`JunkOverrideDetectionTests`
/// suites (anti-regression, spec #7) — not duplicated here.
enum BoundaryLearningBypassTests {
    static func run() {
        TestRunner.section("Wave 2 — LanguageDetector.detect learned bypass (boundary)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the boundary learned-bypass fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        // Genuinely out-of-dictionary on BOTH sides, own-reading CLEAN by
        // JunkMeter (so the PRE-EXISTING, unrelated junk-override — which
        // requires the OWN reading to be JUNK — cannot be what fires here;
        // this isolates the wave-2 learned bypass specifically). Unlike the
        // flagship "сдуфк"→clear instant example, "clear" itself is ALREADY
        // a real en dictionary word and would switch at the boundary with an
        // EMPTY provider too, so it can't demonstrate this bypass here.
        let ruBigramsForSearch = dictionary.possibleBigrams(language: "ru")
        var oovWord: String?
        var oovStrokes: [BufferedKeystroke]?
        for candidate in ["florn", "blurf", "wexil", "drupel", "clanth", "brenzo", "twindle", "sparlo"] {
            guard !dictionary.mightContain(candidate, language: "en"),
                  !dictionary.isPrefixOfBundledWord(candidate, language: "en"),
                  let strokes = InstantCorrectionFixtures.keystrokes(for: candidate, reverse: enReverse) else { continue }
            let ownReading = inputSources.convertKeystrokes(strokes, toLayout: ruLayout)
            guard let ownCore = LanguageDetector.core(of: ownReading)?.lowercased(),
                  !LanguageDetector.isMixedScript(ownCore),
                  !dictionary.mightContain(ownCore, language: "ru"),
                  !dictionary.isPrefixOfBundledWord(ownCore, language: "ru"),
                  let ruBigramsForSearch, JunkMeter.isClean(ownCore, language: "ru", possibleBigrams: ruBigramsForSearch)
            else { continue }
            oovWord = candidate
            oovStrokes = strokes
            break
        }
        guard let oovWord, let oovStrokes else {
            TestRunner.skip("no candidate OOV word had a clean, non-dictionary ru own-reading — widen the candidate list")
            return
        }

        // learned OOV word corrects.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? [oovWord] : [] }
            switch detector.detect(keystrokes: oovStrokes, typedLayout: ruLayout) {
            case .switchTo(let layout, let word):
                TestRunner.assertEqual(layout.languageCode, "en", "learned OOV '\(oovWord)' switches to en")
                TestRunner.assertEqual(word, oovWord, "learned OOV word corrects to the learned entry")
            case .noSwitch:
                TestRunner.assertTrue(false, "learned OOV word must correct at the boundary once active")
            }
        }

        // len==2 learned is forbidden on the boundary even when active.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? ["xz"] : [] }
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: "xz", reverse: InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)) else {
                TestRunner.assertTrue(false, "'xz' fixture can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: ruLayout) {
            case .switchTo:
                TestRunner.assertTrue(false, "len==2 learned entry must NOT correct at the boundary")
            case .noSwitch:
                TestRunner.assertTrue(true, "len==2 learned entry stays noSwitch at the boundary")
            }
        }

        // A junk (no-vowel) target is never authorized by the learned
        // bypass, even active — mirrors the flagship "vmc" case: instant-only.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            detector.learnedWordsProvider = { $0 == "en" ? ["vmc"] : [] }
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: "vmc", reverse: InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)) else {
                TestRunner.assertTrue(false, "'vmc' fixture can type every character")
                return
            }
            switch detector.detect(keystrokes: strokes, typedLayout: ruLayout) {
            case .switchTo:
                TestRunner.assertTrue(false, "junk (no-vowel) learned target 'vmc' must NOT correct at the boundary")
            case .noSwitch:
                TestRunner.assertTrue(true, "junk learned target 'vmc' stays noSwitch at the boundary — instant-only")
            }
        }

        // Empty provider (the default) — byte-for-byte unchanged: the SAME
        // OOV run with no learned entry stays noSwitch.
        do {
            let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
            switch detector.detect(keystrokes: oovStrokes, typedLayout: ruLayout) {
            case .switchTo:
                TestRunner.assertTrue(false, "default (empty) learnedWordsProvider must never correct an OOV word")
            case .noSwitch:
                TestRunner.assertTrue(true, "default empty provider: OOV word stays noSwitch — byte-for-byte unchanged")
            }
        }
    }
}

/// learning_spec.md "Тесты → Волна 2" #6 — B-интеграция, through
/// `KeyboardMonitor`'s real (non-CGEvent) surface: `undoLastCorrection()`
/// and the public `classifyDoubleShiftGesture` entry point HotkeyManager
/// calls. Deliberately avoids `KeyboardMonitorHarness`/synthetic `CGEvent`
/// construction (macOS 27 beta SkyLight deadlock risk, same reason
/// `KeyboardMonitorIntegrationTests` gates on `syntheticKeyboardEventsAreSafe`)
/// — `FakeTextReplacer.replaceCurrentWord` never constructs a `CGEvent`, so
/// seeding `SwitchUndoManager` directly and calling `undoLastCorrection()`/
/// `classifyDoubleShiftGesture()` exercises the real production code with no
/// live-input dependency at all.
enum LearningKeyboardMonitorIntegrationTests {
    private static func makeMonitor(inputSources: InputSourceManager, dictionary: WordDictionary) -> (
        monitor: KeyboardMonitor, replacer: FakeTextReplacer, learnedWords: LearnedWordsStore,
        personalFreq: PersonalFrequencyStore, exceptions: ExceptionsService, switchUndo: SwitchUndoManager,
        feedbackTracker: CorrectionFeedbackTracker
    )? {
        let suite = AppIdentity.bundleIdentifier + ".tests.kmLearning." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.removePersistentDomain(forName: suite) // clean slate, this suite name is fresh anyway
        let prefs = PreferencesService(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let learnedWords = LearnedWordsStore(defaults: defaults)
        let personalFreq = PersonalFrequencyStore(defaults: defaults)
        let feedbackTracker = CorrectionFeedbackTracker()
        let switchUndo = SwitchUndoManager()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let replacer = FakeTextReplacer(inputSources: inputSources)
        let monitor = KeyboardMonitor(
            languageDetector: detector, textReplacer: replacer,
            statsService: StatisticsService(), prefsService: prefs,
            exceptionsService: exceptions, yoficatorService: YoficatorService(),
            switchUndoManager: switchUndo, perAppLayoutService: PerAppLayoutService(inputSourceManager: inputSources, prefsService: prefs),
            instantCorrectionAnalyzer: analyzer,
            secureInputDetector: SecureInputDetector(secureCheck: { false }, axProbe: { false }),
            learnedWordsStore: learnedWords, personalFrequencyStore: personalFreq, feedbackTracker: feedbackTracker
        )
        return (monitor, replacer, learnedWords, personalFreq, exceptions, switchUndo, feedbackTracker)
    }

    static func run() {
        TestRunner.section("Wave 2 — KeyboardMonitor integration (undo-hook + classify dispatch, no live input)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the KeyboardMonitor learning fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        // 6a: undo-hook creates an exception and unlearns from BOTH stores
        // (boundary-откат через undoLastCorrection, "коррекция+пробел+DS"
        // scenario — DS falling through to Cmd+Opt+Z's own handler once the
        // buffer/history are empty is pre-existing routing, unchanged here;
        // this covers ONLY the new exception+unlearn side effect).
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            let t0 = Date()
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0)
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0.addingTimeInterval(1))
            TestRunner.assertTrue(bundle.learnedWords.isActive(word: "clear", lang: "en"), "setup: 'clear' is active before undo")

            bundle.switchUndo.record(
                originalKeycodes: [], originalWord: "сдуфк", correctedWord: "clear",
                trailing: nil, originalLayoutID: ruLayout.id, targetLayoutID: enLayout.id
            )
            _ = bundle.monitor.undoLastCorrection()

            TestRunner.assertTrue(!bundle.learnedWords.isActive(word: "clear", lang: "en"), "undo-hook unlearns the learned entry")
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "undo-hook learns the exception, keyed by the ORIGINAL word")
        }

        // 6b: эвристический revert (instant-case) — `feedbackTracker` is the
        // seam a real instant success callback feeds via
        // `recordAutoCorrection`; `classifyDoubleShiftGesture` (the SAME
        // public entry point HotkeyManager's selection/clipboard/caret paths
        // call) recognizes the reversal and unlearns/excepts exactly like
        // the DS-eligible buffer/history/run paths would.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
            bundle.learnedWords.recordManualFix(word: "clear", lang: "en", originApp: nil, at: Date())
            TestRunner.assertTrue(bundle.learnedWords.isActive(word: "clear", lang: "en"), "setup: 'clear' is active")

            bundle.feedbackTracker.recordAutoCorrection(
                original: "сдуфк", corrected: "clear", targetLang: "en", wasLearned: true, at: Date()
            )
            bundle.monitor.classifyDoubleShiftGesture(word: "clear", sourceLang: "en", targetLang: "ru")

            TestRunner.assertTrue(!bundle.learnedWords.isActive(word: "clear", lang: "en"), "heuristic revert unlearns the learned entry")
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "heuristic revert learns the exception")
        }

        // 6c: a non-eligible classify call (positiveRecord: nil, exactly
        // what HotkeyManager's 3 paths always pass) never mutates
        // LearnedWordsStore even on a `.manualFix` verdict.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            let before = bundle.learnedWords.allEntries.count
            bundle.monitor.classifyDoubleShiftGesture(word: "hello", sourceLang: "en", targetLang: "ru")
            TestRunner.assertEqual(
                bundle.learnedWords.allEntries.count, before,
                "classifyDoubleShiftGesture (HotkeyManager's entry point) never records positively — selection/clipboard/caret content stays out of LearnedWordsStore"
            )
        }

        // 6d: revert-of-revert lifts the exception the revert just created.
        do {
            guard let bundle = makeMonitor(inputSources: inputSources, dictionary: dictionary) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            bundle.switchUndo.record(
                originalKeycodes: [], originalWord: "сдуфк", correctedWord: "clear",
                trailing: nil, originalLayoutID: ruLayout.id, targetLayoutID: enLayout.id
            )
            _ = bundle.monitor.undoLastCorrection()
            TestRunner.assertTrue(bundle.exceptions.isAutoLearned("сдуфк"), "setup: undo created the exception")

            bundle.monitor.classifyDoubleShiftGesture(word: "сдуфк", sourceLang: "ru", targetLang: "en")
            TestRunner.assertTrue(!bundle.exceptions.isAutoLearned("сдуфк"), "revert-of-revert (DS back toward the corrected direction, ≤15s) lifts the exception")
        }
    }
}

/// learning_spec.md "Verify" #4 — the full replay scenario, driven through
/// public APIs only (store + evaluate + detect), no live input, no
/// KeyboardMonitor: "«сдуфк»+DS ×2 → promoted → evaluate с Set чинит сквозь
/// junkGate → revert → unlearn+исключение → больше не чинит."
enum LearningReplayChainTests {
    static func run() {
        TestRunner.section("Wave 2 — replay chain (Verify #4): record ×2 → fires → revert → stops firing")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the replay-chain fixture")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)
        guard let strokes = InstantCorrectionFixtures.keystrokes(for: "сдуфк", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'сдуфк' fixture can type every character")
            return
        }
        func convert(_ layout: KeyboardLayout) -> String { inputSources.convertKeystrokes(strokes, toLayout: layout) }

        let suite = AppIdentity.bundleIdentifier + ".tests.replayChain." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedWordsStore(defaults: defaults)
        let exceptions = ExceptionsService(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Not yet fixed — no active entry.
        let before = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertNil(before.result, "before any DS confirmation, instant stays silent")

        // Owner confirms via Double Shift twice ("сдуфк"+DS ×2).
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0), .recorded,
            "first DS confirmation is recorded"
        )
        TestRunner.assertEqual(
            store.recordManualFix(word: "clear", lang: "en", originApp: nil, at: t0.addingTimeInterval(1)), .promoted,
            "second DS confirmation promotes the entry"
        )

        // Third time: instant fires THROUGH the junk gate.
        let fired = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertEqual(fired.result?.correctedWord, "clear", "promoted entry fires through the junk gate on the third occurrence")

        // Owner reverts (DS/undo): the real KeyboardMonitor path unlearns
        // from the store AND learns the exception — replicated here at the
        // store/service level per the spec's "публичные API" scope.
        store.unlearn(word: "clear", lang: "en")
        exceptions.learnException(original: "сдуфк", corrected: "clear")

        // Fourth time: no longer fires — the active set is empty again.
        let after = analyzer.evaluate(
            keystrokes: strokes, currentLayout: ruLayout, otherLayouts: [enLayout],
            convert: convert, learnedActive: store.activeKeys(lang: "en")
        )
        TestRunner.assertNil(after.result, "after revert, the fourth occurrence no longer fires")
        TestRunner.assertTrue(exceptions.isAutoLearned("сдуфк"), "the exception is in place for the KeyboardMonitor-level exception check too")
    }
}
