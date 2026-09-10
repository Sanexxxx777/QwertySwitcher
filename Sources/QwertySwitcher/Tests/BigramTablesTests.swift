import Foundation

/// Stub registered up front (10.09.2026) so TestRunner.swift is edited exactly
/// once by the orchestrator; the body is filled in by wave W2-B (possible/
/// plausible bigram tables — field data 08-10.09.2026: a single "occurs in
/// >=1 word" table let `yjds` ("новы" typed on en) pass `JunkMeter.isClean`
/// as plausible English, silencing 1372/1444 instant junk-gate checks).
enum BigramTablesTests {
    static func run() {
        BigramThresholdTableTests.run()
        JunkMeterCallSiteGuardTests.run()
        BigramThresholdPortSyncTests.run()
        DictionaryWordNeverBlockedTests.run()
        PlausibleTableLiveTests.run()
    }
}

/// `WordDictionary.buildBigramTables` — pure, on a small closed word list
/// (not the ~700K-word bundled dictionaries), so the exact counts are
/// hand-verifiable.
enum BigramThresholdTableTests {
    static func run() {
        TestRunner.section("WordDictionary.buildBigramTables — pure bigram-table builder")

        // "cat"->ca,at  "car"->ca,ar  "dog"->do,og  "do"/"zz" are len<3, EXCLUDED.
        // Per-word counts: ca=2 (cat,car), at=1, ar=1, do=1, og=1.
        let words = ["cat", "car", "dog", "do", "zz"]

        let k1 = WordDictionary.buildBigramTables(words: words, minWords: 1)
        TestRunner.assertEqual(
            k1.possible, Set(["ca", "at", "ar", "do", "og"]),
            "K=1: possible is every bigram occurring in >=1 qualifying (len>=3) word"
        )
        TestRunner.assertEqual(
            k1.plausible, k1.possible,
            "K=1: plausible reproduces possible byte-for-byte (this IS the old single-table behavior)"
        )
        TestRunner.assertTrue(
            !k1.possible.contains("zz"),
            "len<3 words never contribute a bigram, even one matching their own 2 letters exactly"
        )

        let k2 = WordDictionary.buildBigramTables(words: words, minWords: 2)
        TestRunner.assertEqual(
            k2.plausible, Set(["ca"]),
            "K=2: only 'ca' (2 words) clears the bar — 'at'/'ar'/'do'/'og' (1 word each) are excluded"
        )
        TestRunner.assertEqual(
            k2.possible, k1.possible,
            "raising minWords never shrinks `possible` — it only narrows `plausible`"
        )

        // A bigram repeated WITHIN one word counts that word once, not twice
        // (word-level presence, not raw occurrence) — "assess" contains "ss"
        // twice but must only count as 1 toward "ss"'s word-count.
        let repeated = WordDictionary.buildBigramTables(words: ["assess", "mess"], minWords: 2)
        TestRunner.assertTrue(
            repeated.plausible.contains("ss"),
            "'ss' occurs in 2 DISTINCT words (assess, mess) — clears K=2 even though 'assess' alone has it twice"
        )
        let single = WordDictionary.buildBigramTables(words: ["assess"], minWords: 2)
        TestRunner.assertTrue(
            !single.plausible.contains("ss"),
            "'ss' repeated twice WITHIN one single word still counts as only 1 word — does not clear K=2 alone"
        )
    }
}

/// Structural guard (`#filePath`, same precedent as `ReplacementAtomicityGuardTests`/
/// `IslandStructuralGuardTests`): every `JunkMeter.isJunk(`/`isClean(` call
/// site in `LanguageDetector.swift`/`InstantCorrectionAnalyzer.swift` is fed
/// from the correct table — `isJunk` (own-reading junk-ness, the "russian
/// typo -> latin garbage" class) always from `possibleBigrams`, `isClean`
/// (plausibility of anything the caller is about to trust/silence-on)
/// always from `plausibleBigrams`. Written against the EXACT variable names
/// in the real source, not a fuzzy pattern match — this is meant to catch a
/// future accidental swap, not to survive an unrelated rewrite untouched.
enum JunkMeterCallSiteGuardTests {
    private static func readSource(_ path: String) -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            TestRunner.skip("\(path) not readable from \(url.path)")
            return nil
        }
        return text
    }

    static func run() {
        TestRunner.section("JunkMeter call sites — isJunk always possible, isClean always plausible")

        guard let ldText = readSource("Core/LanguageDetector.swift") else { return }

        // junkOverrideFires: own -> possible -> isJunk; target -> plausible -> isClean.
        if let funcStart = ldText.range(of: "private func junkOverrideFires("),
           let nextFunc = ldText.range(of: "\n    /// Junk-override is disabled") {
            let scoped = String(ldText[funcStart.upperBound..<nextFunc.lowerBound])
            TestRunner.assertTrue(
                scoped.contains("let ownBigrams = dictionary.possibleBigrams(language: ownLang)"),
                "junkOverrideFires: ownBigrams (feeds isJunk) is sourced from possibleBigrams"
            )
            TestRunner.assertTrue(
                scoped.contains("let targetBigrams = dictionary.plausibleBigrams(language: targetLang)"),
                "junkOverrideFires: targetBigrams (feeds isClean) is sourced from plausibleBigrams"
            )
            TestRunner.assertTrue(
                scoped.contains("JunkMeter.isJunk(ownCore, language: ownLang, possibleBigrams: ownBigrams)"),
                "junkOverrideFires: isJunk receives ownBigrams (possible), not targetBigrams (plausible)"
            )
            TestRunner.assertTrue(
                scoped.contains("JunkMeter.isClean(targetCore, language: targetLang, possibleBigrams: targetBigrams)"),
                "junkOverrideFires: isClean receives targetBigrams (plausible), not ownBigrams (possible)"
            )
        } else {
            TestRunner.assertTrue(false, "junkOverrideFires not found — test needs updating")
        }

        // isCleanReading: own reading -> plausible -> isClean (Mechanism C bump gate).
        if let funcStart = ldText.range(of: "func isCleanReading(_ core: String, language: String) -> Bool {"),
           let nextFunc = ldText.range(of: "\n    /// Mechanism A write-time guard") {
            let scoped = String(ldText[funcStart.upperBound..<nextFunc.lowerBound])
            TestRunner.assertTrue(
                scoped.contains("let bigrams = dictionary.plausibleBigrams(language: language)"),
                "isCleanReading: sourced from plausibleBigrams"
            )
            TestRunner.assertTrue(
                !scoped.contains("dictionary.possibleBigrams"),
                "isCleanReading: never falls back to possibleBigrams"
            )
        } else {
            TestRunner.assertTrue(false, "isCleanReading not found — test needs updating")
        }

        // learnedHitApplies no longer calls JunkMeter at all (previous wave,
        // short-token fix) — guard that this stays true, not just today.
        if let funcStart = ldText.range(of: "func learnedHitApplies(core: String, lang: String) -> Bool {"),
           let funcEnd = ldText.range(of: "\n    }", range: funcStart.upperBound..<ldText.endIndex) {
            let scoped = String(ldText[funcStart.upperBound..<funcEnd.lowerBound])
            TestRunner.assertTrue(
                !scoped.contains("JunkMeter"),
                "learnedHitApplies never calls JunkMeter (exact learned match uses isMixedScript only)"
            )
        } else {
            TestRunner.assertTrue(false, "learnedHitApplies not found — test needs updating")
        }

        // InstantCorrectionAnalyzer's own-reading junk-gate -> plausible -> isClean.
        guard let icaText = readSource("Core/InstantCorrectionAnalyzer.swift") else { return }
        TestRunner.assertTrue(
            icaText.contains("dictionary.plausibleBigrams(language: currentLayout.languageCode)"),
            "InstantCorrectionAnalyzer junk-gate: sourced from plausibleBigrams"
        )
        TestRunner.assertTrue(
            icaText.contains("JunkMeter.isClean(currentText, language: currentLayout.languageCode, possibleBigrams: bigrams)"),
            "InstantCorrectionAnalyzer junk-gate: isClean receives the plausible-sourced bigrams"
        )
        TestRunner.assertTrue(
            !icaText.contains("dictionary.possibleBigrams"),
            "InstantCorrectionAnalyzer never reads possibleBigrams — it has no isJunk call at all"
        )
    }
}

/// K must be the SAME literal number in `WordDictionary.plausibleMinWords`
/// and `Scripts/research/false_switch_sim.py`'s `_plausible_min_words()`
/// default — otherwise the stand is calibrating a different algorithm than
/// what ships. Read via `#filePath`, same precedent as the guards above.
enum BigramThresholdPortSyncTests {
    static func run() {
        TestRunner.section("plausibleMinWords — Swift/Python K stays in sync")

        let swiftURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Dictionary/WordDictionary.swift")
        let pyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/research/false_switch_sim.py")

        guard let swiftText = try? String(contentsOf: swiftURL, encoding: .utf8) else {
            TestRunner.skip("WordDictionary.swift not readable from \(swiftURL.path)")
            return
        }
        guard let pyText = try? String(contentsOf: pyURL, encoding: .utf8) else {
            TestRunner.skip("false_switch_sim.py not readable from \(pyURL.path)")
            return
        }

        guard let swiftRegex = try? NSRegularExpression(pattern: #"static let plausibleMinWords = (\d+)"#),
              let swiftMatch = swiftRegex.firstMatch(
                  in: swiftText, range: NSRange(swiftText.startIndex..., in: swiftText)
              ),
              let swiftRange = Range(swiftMatch.range(at: 1), in: swiftText) else {
            TestRunner.assertTrue(false, "plausibleMinWords declaration not found in WordDictionary.swift — test needs updating")
            return
        }
        let swiftK = Int(swiftText[swiftRange])

        // The DEFAULT return in `_plausible_min_words()` — 4-space indent,
        // distinguishing it from the two 8-space-indented conditional
        // returns (`--plausible-min=`/env override) above it.
        guard let pyRegex = try? NSRegularExpression(pattern: #"\n    return (\d+)\n\n\nPLAUSIBLE_MIN_WORDS"#),
              let pyMatch = pyRegex.firstMatch(in: pyText, range: NSRange(pyText.startIndex..., in: pyText)),
              let pyRange = Range(pyMatch.range(at: 1), in: pyText) else {
            TestRunner.assertTrue(false, "_plausible_min_words() default return not found in false_switch_sim.py — test needs updating")
            return
        }
        let pyK = Int(pyText[pyRange])

        TestRunner.assertTrue(swiftK != nil && pyK != nil, "both K values parsed as integers")
        TestRunner.assertEqual(swiftK ?? -1, pyK ?? -2, "plausibleMinWords (Swift) == PLAUSIBLE_MIN_WORDS default (Python)")
    }
}

/// A dictionary word with a genuinely rare bigram must stay `.noSwitch` at
/// ANY K — the boundary path's protection comes from `scoreWord`/dictionary
/// membership (`junkOverrideFires`'s OWN guard `scoreWord(ownCore,...) == 0`
/// refuses to even consider a word that already scores as a real dictionary
/// hit), never from the bigram table. Real words, not synthetic strings:
/// «взъярен» (ru, contains «ъя») and "pirojki" (en, contains "jk" — both
/// bundled).
enum DictionaryWordNeverBlockedTests {
    static func run() {
        TestRunner.section("Dictionary word with a rare bigram — never touched at the boundary, any K")

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for this fixture")
            return
        }
        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)

        let ruReverse = BigramTestFixtures.reverseMap(for: ruLayout, inputSources: inputSources)
        let enReverse = BigramTestFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        guard let vzyarenStrokes = BigramTestFixtures.keystrokes(for: "взъярен", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«взъярен»: ru fixture layout can type every character")
            return
        }
        TestRunner.assertTrue(
            dictionary.containsBundled("взъярен", language: "ru") == true,
            "sanity: «взъярен» (contains «ъя») is a real bundled ru word"
        )
        detector.resetContext()
        switch detector.detect(keystrokes: vzyarenStrokes, typedLayout: ruLayout) {
        case .noSwitch:
            TestRunner.assertTrue(true, "«взъярен» typed honestly on ru: noSwitch, despite «ъя» being a rare bigram")
        case .switchTo:
            TestRunner.assertTrue(false, "«взъярен» must stay noSwitch — a real dictionary word is never perturbed by the bigram table")
        }

        guard let pirojkiStrokes = BigramTestFixtures.keystrokes(for: "pirojki", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'pirojki': en fixture layout can type every character")
            return
        }
        TestRunner.assertTrue(
            dictionary.containsBundled("pirojki", language: "en") == true,
            "sanity: 'pirojki' (contains 'jk') is a real bundled en word"
        )
        detector.resetContext()
        switch detector.detect(keystrokes: pirojkiStrokes, typedLayout: enLayout) {
        case .noSwitch:
            TestRunner.assertTrue(true, "'pirojki' typed honestly on en: noSwitch, despite 'jk' being a rare bigram")
        case .switchTo:
            TestRunner.assertTrue(false, "'pirojki' must stay noSwitch — a real dictionary word is never perturbed by the bigram table")
        }
    }
}

/// Against the REAL bundled dictionaries, post-index-build. Confirms the
/// live K=8 tables actually shape up as expected and reproduces the exact
/// field mechanism the fix targets.
enum PlausibleTableLiveTests {
    static func run() {
        TestRunner.section("plausibleBigrams/possibleBigrams — live K=8 tables against the real dictionaries")

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        guard let plausible = dictionary.plausibleBigrams(language: "en"),
              let possible = dictionary.possibleBigrams(language: "en") else {
            TestRunner.assertTrue(false, "en bigram tables not ready after waitUntilPrefixIndexReady — test needs updating")
            return
        }

        // "jk" (5 words) and "fj" (7 words) both fall below K=8 — excluded
        // from plausible, still present in possible (count >= 1).
        for rare in ["jk", "fj"] {
            TestRunner.assertTrue(!plausible.contains(rare), "'\(rare)': below K=8, excluded from plausible")
            TestRunner.assertTrue(possible.contains(rare), "'\(rare)': still present in possible (count >= 1)")
        }
        // Common bigrams clear K=8 comfortably.
        for common in ["th", "er"] {
            TestRunner.assertTrue(plausible.contains(common), "'\(common)': common bigram clears K=8")
        }

        // "yj" itself occurs in 10 words — it DOES clear K=8 and stays
        // plausible on its own (verified against the bundled dictionary,
        // not assumed from the field write-up's illustrative counts). The
        // field word "yjds" ("новы" typed on en) is still correctly
        // rejected as a plausible English target — NOT via "yj", but via
        // "jd" (7 words, below K=8). Both bigrams matter; only one has to
        // fail for the whole word to fail `isClean`.
        TestRunner.assertTrue(possible.contains("yj"), "'yj': present in possible")
        TestRunner.assertTrue(plausible.contains("yj"), "'yj' alone clears K=8 (10 words) — the fix works via 'jd', not 'yj'")
        TestRunner.assertTrue(!plausible.contains("jd"), "'jd': below K=8 (7 words) — this is what actually blocks 'yjds'")

        TestRunner.assertTrue(
            JunkMeter.isClean("yjds", language: "en", possibleBigrams: possible),
            "'yjds' against the OLD single (possible) table: clean — this was the bug"
        )
        TestRunner.assertTrue(
            !JunkMeter.isClean("yjds", language: "en", possibleBigrams: plausible),
            "'yjds' against the NEW plausible (K=8) table: NOT clean — this is the fix"
        )
    }
}

/// Copied from `DetectorExactnessTests.swift`'s `private enum
/// DetectorExactnessFixtures` (file-private there, unreachable from this
/// file) — same two helpers, unchanged, same established precedent.
private enum BigramTestFixtures {
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
