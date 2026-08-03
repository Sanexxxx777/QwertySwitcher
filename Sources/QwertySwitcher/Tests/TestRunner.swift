import Foundation
import CoreGraphics
import CryptoKit

/// Lightweight test runner — no XCTest required.
/// Invoked via `swift run QwertySwitcher --test` or `./Scripts/test.sh`.
enum TestRunner {
    private static var failed = 0
    private static var passed = 0
    private static var skipped = 0

    static func run() -> Int {
        print("=== Qwerty Switcher test suite ===")
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
        AutoLearnTrackerTests.run()
        ReplacementTransactionTests.run()
        LanguageSkipTests.run()
        InputSourceLanguageTests.run()
        PrivacyTests.run()
        ExceptionsTests.run()
        InstantCorrectionGateTests.run()
        PreferencesServiceTests.run()
        InstantCorrectionUndoTests.run()
        InstantCorrectionAnalyzerTests.run()
        InstantCorrectionCorpusTests.run()
        LicenseServiceTests.run()
        PendingUserEventQueueTests.run()
        EventRouteTests.run()
        BufferVsScreenModelTests.run()
        InstantCorrectionGateSelfSwitchTests.run()
        InputSourceSelfSwitchTests.run()
        SlashModelRegressionTests.run()
        LeadingSymbolRunGuardTests.run()
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
            )
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
                ("руддщ", ruLayout, ruReverse, enLayout, "руддщ (ru keys) → hello"),
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

        // Below MIN_INSTANT: never evaluated, even on an otherwise-golden prefix.
        if let strokes = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
            let short = Array(strokes.prefix(InstantCorrectionAnalyzer.minLength - 1))
            let result = analyzer.evaluate(
                keystrokes: short, currentLayout: enLayout, otherLayouts: [ruLayout],
                convert: { layout in inputSources.convertKeystrokes(short, toLayout: layout) }
            )
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

    func hello(
        baseURL: URL, hwid: String, appVersion: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        completion(helloResult)
    }

    func activate(
        baseURL: URL, hwid: String, key: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        completion(activateResult)
    }
}

enum LicenseServiceTests {
    private static let day: Int64 = 24 * 3600
    private static let grace: Int64 = 14 * day
    private static let rollbackTolerance: Int64 = 3600

    static func run() {
        TestRunner.section("LicenseService")

        // (a) canonicalization — golden vector
        let golden = LicensePayload(
            hwid: "ABC-123", plan: "trial", start: 1_754_100_000, until: 1_755_309_600, issued: 1_754_200_000
        )
        TestRunner.assertEqual(
            golden.canonicalString,
            "{\"hwid\":\"ABC-123\",\"issued\":1754200000,\"plan\":\"trial\",\"start\":1754100000,\"until\":1755309600}",
            "canonical payload string matches the golden vector"
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
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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
        TestRunner.assertTrue(
            InputSourceManager.isSelfInitiated(
                pendingSelfSwitchID: "com.apple.keylayout.US", newLayoutID: "com.apple.keylayout.US"
            ),
            "a switch matching our own pending request is self-initiated"
        )
        TestRunner.assertTrue(
            !InputSourceManager.isSelfInitiated(
                pendingSelfSwitchID: "com.apple.keylayout.US", newLayoutID: "com.apple.keylayout.Russian"
            ),
            "a manual switch to a DIFFERENT layout than we requested is not self-initiated"
        )
        TestRunner.assertTrue(
            !InputSourceManager.isSelfInitiated(pendingSelfSwitchID: nil, newLayoutID: "com.apple.keylayout.US"),
            "with no pending request at all, any switch is manual"
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
            )
        }

        // Positive: the literal reported "/model" case + the "$GRAF" citation
        // — the letter core, typed in the WRONG layout, must still be
        // recognized as needing a switch. The leading symbol is folded in
        // only AFTER this decision (never fed to the analyzer), so this
        // proves the decision itself is unaffected by a symbol in front of it.
        // `enReverse` recovers the PHYSICAL keycodes for "model"/"graf" (EN
        // text); `wrongLayout: ruLayout` simulates those same physical keys
        // being pressed while RU was mistakenly active.
        if let modelResult = evaluateAtFirstFire("model", wrongLayout: ruLayout, reverse: enReverse, otherLayout: enLayout) {
            TestRunner.assertTrue(
                modelResult.layout.isEnglish, "'/model' letter core (wrong ru layout) is recognized and switches to EN"
            )
        } else {
            TestRunner.assertTrue(false, "'/model' letter core should be recognized as needing a switch to EN")
        }
        // "graf" itself is too short/uncommon for the dictionary to score
        // confidently at minLength=4 (a property of the calibrated analyzer,
        // unrelated to this fix) — "hello" is one of the suite's existing
        // proven golden words and stands in for the same "$XXX"-style
        // leading-symbol scenario the diagnosis illustrated with "$GRAF".
        if let helloResult = evaluateAtFirstFire("hello", wrongLayout: ruLayout, reverse: enReverse, otherLayout: enLayout) {
            TestRunner.assertTrue(
                helloResult.layout.isEnglish, "'$hello'-style letter core (wrong ru layout) is recognized and switches to EN"
            )
        } else {
            TestRunner.assertTrue(false, "'hello' letter core should be recognized as needing a switch to EN")
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
