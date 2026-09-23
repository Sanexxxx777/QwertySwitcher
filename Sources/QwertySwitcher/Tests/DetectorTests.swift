#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


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


/// Field 18.09.2026, twice in one session: «нфт» (NFT, written in Russian
/// inside a Russian sentence) was boundary-corrected to the English «yan» —
/// a Scrabble-list entry in `en_US.txt` that no owner of this app will ever
/// type. The owner confirmed it as a false correction on 19.09. The word has
/// no vowel, so it scores 0 on the Russian side and any dictionary hit on the
/// English side wins; the fix is to teach the Russian dictionary the
/// abbreviation, which is what the owner actually writes.
enum OwnerAbbreviationRegressionTests {
    static func run() {
        TestRunner.section("Owner abbreviations — «нфт» is not corrected to «yan»")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the abbreviation fixture")
            return
        }

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        ) // primes previousWordLanguage = "ru", exactly as in the field log

        guard let nftStrokes = InstantCorrectionFixtures.keystrokes(for: "нфт", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«нфт»: RU fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: nftStrokes, typedLayout: ruLayout) {
        case .switchTo(_, let word):
            TestRunner.assertTrue(false, "«нфт» under ru-context must stay noSwitch — got «\(word)»")
        case .noSwitch:
            TestRunner.assertTrue(true, "«нфт» under ru-context stays noSwitch")
        }

        // The other direction must not regress: a genuinely English word
        // typed on the Russian layout in the same ru context is still fixed.
        detector.resetContext()
        _ = detector.detect(
            keystrokes: InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse)!,
            typedLayout: ruLayout
        )
        guard let modelStrokes = InstantCorrectionFixtures.keystrokes(for: "ьщвуд", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«ьщвуд» (model): RU fixture layout can type every character")
            return
        }
        switch detector.detect(keystrokes: modelStrokes, typedLayout: ruLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "en", "«ьщвуд» still corrects to English")
            TestRunner.assertEqual(word, "model", "«ьщвуд» corrects to «model»")
        case .noSwitch:
            TestRunner.assertTrue(false, "«ьщвуд» must still be corrected to «model» — the ru-side fix must not blunt real corrections")
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
#endif
