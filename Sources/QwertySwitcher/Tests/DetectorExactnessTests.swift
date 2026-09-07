import Foundation

/// Field facts 07–08.09.2026 (owner's verbose-log capture) drove two
/// independent fixes, both exercised here directly against the real classes:
///
/// 1. `jgnbvbpbhjdfyyhj`, `ghjghwb`, `erfposdf` are NOT in
///    `Resources/Dictionaries/en_US.txt` (grepped), yet the live Bloom cache
///    on the owner's Mac answered `true` for all three — `mightContain` was
///    the ONLY membership check on both the boundary path
///    (`LanguageDetector.scoreWord`) and the instant path
///    (`InstantCorrectionAnalyzer.wordLevelScore`), so each false positive
///    flipped a Russian typo into Latin garbage. `WordDictionary.isConfirmedWord`
///    now resolves the rare Bloom positive with an exact binary search.
/// 2. A Cyrillic-only physical key (б ж э х ъ ю ё) renders as punctuation on
///    the Latin side — no English word begins with punctuation, so a reading
///    that turns the user's own FIRST typed letter into a leading comma is
///    not a candidate ("боут"→",jen", field 08.09.2026). Fixed in
///    `LanguageDetector.projections()`.
enum DetectorExactnessTests {
    static func run() {
        TestRunner.section("Detector exactness — Bloom exact-confirm + leading-letter guard (field 07–08.09.2026)")

        // --- 1: WordDictionary.containsBundled / isConfirmedWord — exact
        // membership resolves the Bloom false positive. `mightContain` itself
        // is deliberately not asserted on (the Bloom cache can differ across
        // machines); `containsBundled`/`isConfirmedWord` are the contract
        // that must hold regardless of what the Bloom filter happens to say. ---
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        TestRunner.assertTrue(
            dictionary.containsBundled("clear", language: "en") == true,
            "containsBundled: 'clear' is a real bundled en word"
        )
        TestRunner.assertTrue(
            dictionary.containsBundled("привет", language: "ru") == true,
            "containsBundled: 'привет' is a real bundled ru word"
        )
        TestRunner.assertTrue(
            dictionary.containsBundled("jgnbvbpbhjdfyyhj", language: "en") == false,
            "containsBundled: Bloom false positive #1 (boundary 'оптимизированнро'→this) is NOT a real en word"
        )
        TestRunner.assertTrue(
            dictionary.containsBundled("ghjghwb", language: "en") == false,
            "containsBundled: Bloom false positive #2 (boundary 'пропрцию'→this) is NOT a real en word"
        )
        TestRunner.assertTrue(
            dictionary.containsBundled("erfposdf", language: "en") == false,
            "containsBundled: Bloom false positive #3 (instant 'указщыва'→this) is NOT a real en word"
        )

        TestRunner.assertTrue(dictionary.isConfirmedWord("clear", language: "en"), "isConfirmedWord: 'clear' confirmed")
        TestRunner.assertTrue(dictionary.isConfirmedWord("привет", language: "ru"), "isConfirmedWord: 'привет' confirmed")
        TestRunner.assertTrue(
            !dictionary.isConfirmedWord("jgnbvbpbhjdfyyhj", language: "en"),
            "isConfirmedWord: Bloom false positive #1 rejected by exact confirm"
        )
        TestRunner.assertTrue(
            !dictionary.isConfirmedWord("ghjghwb", language: "en"),
            "isConfirmedWord: Bloom false positive #2 rejected by exact confirm"
        )
        TestRunner.assertTrue(
            !dictionary.isConfirmedWord("erfposdf", language: "en"),
            "isConfirmedWord: Bloom false positive #3 rejected by exact confirm"
        )

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for LanguageDetector/InstantCorrectionAnalyzer fixtures")
            return
        }

        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let enReverse = DetectorExactnessFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        // --- 2a: «боут» (ru) typed on ru layout / ",jen" (en reading of the
        // SAME physical keys) — the leading б-as-comma reading is not a
        // candidate. Pre-fix this switched to en "jen" (a real bundled word,
        // field 08.09.2026: comma renders as б on ru, core(of: ",jen") =
        // "jen" wins outright). ---
        detector.resetContext()
        let boutStrokes = [
            BufferedKeystroke(keycode: 43, flags: []), // б (renders "," on en)
            BufferedKeystroke(keycode: 38, flags: []), // о / j
            BufferedKeystroke(keycode: 14, flags: []), // у / e
            BufferedKeystroke(keycode: 45, flags: []), // т / n
        ]
        switch detector.detect(keystrokes: boutStrokes, typedLayout: ruLayout) {
        case .switchTo:
            TestRunner.assertTrue(
                false, "«боут»→',jen': must stay noSwitch — leading б-as-comma reading is not a candidate (field 08.09.2026)"
            )
        case .noSwitch:
            TestRunner.assertTrue(true, "«боут»→',jen': stays noSwitch — leading-letter guard holds")
        }

        // --- 2b: control — "ghbdtn." typed on en still corrects to
        // "привет.": trailing-punctuation peeling is untouched by the guard
        // (asTyped starts with a letter, and so does the head-only reading). ---
        detector.resetContext()
        guard var ghbdtnStrokes = DetectorExactnessFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn': en fixture layout can type every character")
            return
        }
        ghbdtnStrokes.append(BufferedKeystroke(keycode: 47, flags: [])) // trailing "."
        switch detector.detect(keystrokes: ghbdtnStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "'ghbdtn.' control: still switches to ru")
            TestRunner.assertEqual(word, "привет.", "'ghbdtn.' control: trailing '.' still peeled off exactly as typed")
        case .noSwitch:
            TestRunner.assertTrue(false, "'ghbdtn.' control: must still switch — trailing-punctuation peel is untouched")
        }

        // --- 2c: mirror control — ",jn" (en) / "бот" (ru) — the OTHER
        // direction GAINS a letter (comma physical key renders as б, a
        // letter, on ru) and must stay untouched by the guard. ---
        detector.resetContext()
        let jnStrokes = [
            BufferedKeystroke(keycode: 43, flags: []), // , / б
            BufferedKeystroke(keycode: 38, flags: []), // j / о
            BufferedKeystroke(keycode: 45, flags: []), // n / т
        ]
        switch detector.detect(keystrokes: jnStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "ru", "',jn'→«бот» mirror control: switches to ru")
            TestRunner.assertEqual(word, "бот", "',jn'→«бот» mirror control: corrects to «бот»")
        case .noSwitch:
            TestRunner.assertTrue(false, "',jn'→«бот» mirror control: must still switch — gaining a letter is untouched")
        }

        // --- 3: InstantCorrectionAnalyzer — the Bloom false positive that
        // used to fire at keystroke 8 ("erfposdf") now stays silent at every
        // prefix length; none of its length>=4 prefixes are a real bundled
        // word or a real bundled prefix (grepped), so the ONLY thing that
        // ever made it fire was the Bloom false positive on the full string. ---
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        guard let erfposdfStrokes = DetectorExactnessFixtures.keystrokes(for: "erfposdf", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'erfposdf': en fixture layout can type every character")
            return
        }
        for length in InstantCorrectionAnalyzer.minLength...erfposdfStrokes.count {
            let prefix = Array(erfposdfStrokes.prefix(length))
            let result = analyzer.evaluate(
                keystrokes: prefix, currentLayout: ruLayout, otherLayouts: [enLayout],
                convert: { layout in inputSources.convertKeystrokes(prefix, toLayout: layout) }
            ).result
            TestRunner.assertNil(
                result,
                "'erfposdf' (Bloom false positive #3, field 08.09.2026): instant stays silent at length \(length) (used to fire at length 8)"
            )
        }

        // Control: honest "ghbdtn" on en still fires by length 7, exactly as
        // the golden case in InstantCorrectionAnalyzerTests — the Bloom
        // exact-confirm swap did not regress an ordinary dictionary hit.
        guard let ghbdtnInstantStrokes = DetectorExactnessFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn' (instant control): en fixture layout can type every character")
            return
        }
        var firedLength: Int?
        for length in InstantCorrectionAnalyzer.minLength...ghbdtnInstantStrokes.count {
            let prefix = Array(ghbdtnInstantStrokes.prefix(length))
            let result = analyzer.evaluate(
                keystrokes: prefix, currentLayout: enLayout, otherLayouts: [ruLayout],
                convert: { layout in inputSources.convertKeystrokes(prefix, toLayout: layout) }
            ).result
            if result != nil { firedLength = length; break }
        }
        TestRunner.assertTrue(
            firedLength != nil && firedLength! <= 7,
            "'ghbdtn' (instant control): still fires by length 7 (fired at \(firedLength.map(String.init) ?? "never"))"
        )
    }
}

/// Copied from `TestRunner.swift`'s `private enum InstantCorrectionFixtures`
/// (that type is file-private there, unreachable from this file) — only the
/// two helpers this suite needs, unchanged.
private enum DetectorExactnessFixtures {
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
}
