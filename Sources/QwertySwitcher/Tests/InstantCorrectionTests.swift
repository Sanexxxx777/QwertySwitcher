#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


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
enum InstantCorrectionFixtures {
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

        // Sanity cap (gamemode-spec-20260831.md §4): longer than maxLength
        // never evaluates a candidate at all — the guard fires before ANY
        // scoring, so the specific content of the run doesn't matter here.
        let overLength = InstantCorrectionAnalyzer.maxLength + 1
        if let over = InstantCorrectionFixtures.keystrokes(
            for: String(repeating: "a", count: overLength), reverse: enReverse
        ) {
            let evaluation = analyzer.evaluate(
                keystrokes: over, currentLayout: enLayout, otherLayouts: [ruLayout],
                convert: { layout in inputSources.convertKeystrokes(over, toLayout: layout) }
            )
            TestRunner.assertNil(evaluation.result, "\(overLength) keystrokes: never evaluates a candidate")
            TestRunner.assertEqual(
                evaluation.silence, .tooLong, "\(overLength) keystrokes: silence reason is .tooLong"
            )
        } else {
            TestRunner.assertTrue(false, "\(overLength)×'a': en fixture can type every character")
        }
        // Exactly at the cap: unaffected (whatever the ordinary silence
        // reason turns out to be, it must not be .tooLong).
        if let atCap = InstantCorrectionFixtures.keystrokes(
            for: String(repeating: "a", count: InstantCorrectionAnalyzer.maxLength), reverse: enReverse
        ) {
            let evaluation = analyzer.evaluate(
                keystrokes: atCap, currentLayout: enLayout, otherLayouts: [ruLayout],
                convert: { layout in inputSources.convertKeystrokes(atCap, toLayout: layout) }
            )
            TestRunner.assertTrue(
                evaluation.silence != .tooLong,
                "exactly \(InstantCorrectionAnalyzer.maxLength) keystrokes: not gated by the length cap"
            )
        } else {
            TestRunner.assertTrue(false, "\(InstantCorrectionAnalyzer.maxLength)×'a': en fixture can type every character")
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
#endif
