import Foundation
import CoreGraphics

/// Lightweight test runner — no XCTest required.
/// Invoked via `swift run SashaSwitcher --test` or `./Scripts/test.sh`.
enum TestRunner {
    private static var failed = 0
    private static var passed = 0
    private static var skipped = 0

    static func run() -> Int {
        print("=== Qwerty Switch test suite ===")
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
            "replayed user event bypasses Qwerty Switch analysis"
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
