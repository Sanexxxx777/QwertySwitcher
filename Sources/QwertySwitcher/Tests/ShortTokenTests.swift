import Foundation

/// Stub registered up front (10.09.2026) so TestRunner.swift is edited exactly
/// once by the orchestrator; the body is filled in by wave W2-A (2-3-letter
/// learned tokens — field data 08-10.09.2026: 21 of 38 Double Shift ru→en
/// fixes were tokens ≤3 letters, bsc/okx/xrp/arb/sc/hh/ff, and neither the
/// write gate (`KeyboardMonitor.normalizedLearnableCore`, floor was 3) nor
/// the apply gate (`LanguageDetector.learnedHitApplies`, required a vowel)
/// could ever have learned them, even after manual confirmation).
enum ShortTokenTests {
    static func run() {
        LearnedShortTokenWriteGateTests.run()
        LearnedVowellessApplyTests.run()
        LearnedTwoLetterIncumbentTests.run()
    }
}

/// `KeyboardMonitor.learnableCoreDecision` is the pure decision core of
/// `normalizedLearnableCore` (extracted specifically for this suite — see
/// its own doc comment). No live app object graph needed: `isDictionaryWord`
/// is a plain closure fixture here, not a real `LanguageDetector` — this
/// suite is about the GATE's own logic (length floor, reserved list, the new
/// `ownIsWord` guard), not about real dictionary contents (that's
/// `LearnedTwoLetterIncumbentTests` below, against a real detector).
enum LearnedShortTokenWriteGateTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.learnableCoreDecision — short-token write gate")

        // hh/sc — 2-letter tokens, own reading is garbage (not a dictionary
        // word in either language) → learnable. The closure is asserted
        // NOT called for 3-letter cores below (ownIsWord is scoped to
        // length 2 only), so returning `true` here would still be safe —
        // it's `false` because that is genuinely the field case.
        for (token, ownGarbage) in [("hh", "рр"), ("sc", "ыс")] {
            let decision = KeyboardMonitor.learnableCoreDecision(
                from: token, lang: "en", own: ownGarbage, ownLang: "ru", resynced: false,
                isDictionaryWord: { _, _ in false }
            )
            TestRunner.assertEqual(decision.core ?? "MISSING", token, "'\(token)' (len 2, own reading is junk): learns")
            TestRunner.assertNil(decision.rejectReason, "'\(token)': no rejection reason")
        }

        // bsc/okx — 3-letter tokens: the ownIsWord guard must not even run
        // (scoped to length 2), proven by a closure that records whether it
        // was called at all.
        for token in ["bsc", "okx"] {
            var isDictionaryWordCalled = false
            let decision = KeyboardMonitor.learnableCoreDecision(
                from: token, lang: "en", own: "щлч", ownLang: "ru", resynced: false,
                isDictionaryWord: { _, _ in isDictionaryWordCalled = true; return true }
            )
            TestRunner.assertEqual(decision.core ?? "MISSING", token, "'\(token)' (len 3): learns")
            TestRunner.assertNil(decision.rejectReason, "'\(token)': no rejection reason")
            TestRunner.assertTrue(
                !isDictionaryWordCalled,
                "'\(token)': the ownIsWord dictionary check never runs for a length-3 core"
            )
        }

        // «он» (own reading "jy" of the SAME two keys) is a real ru
        // dictionary word — learning the pair would mean a future HONEST
        // «он» risks getting silently "corrected" into "jy". The closure
        // fixture stands in for `LanguageDetector.isDictionaryWord` here;
        // `LearnedTwoLetterIncumbentTests` below proves the real thing.
        let onDecision = KeyboardMonitor.learnableCoreDecision(
            from: "jy", lang: "en", own: "он", ownLang: "ru", resynced: false,
            isDictionaryWord: { word, lang in word == "он" && lang == "ru" }
        )
        TestRunner.assertNil(onDecision.core, "'jy' (own «он» is a real ru word): does not learn")
        TestRunner.assertEqual(onDecision.rejectReason ?? "MISSING", "ownIsWord", "'jy': rejected as ownIsWord")

        // vs/мы — both sides of a `conflictPairs` entry stay reserved,
        // exactly as before this fix (`isReservedForDisambiguation` itself
        // is untouched).
        let vsDecision = KeyboardMonitor.learnableCoreDecision(
            from: "vs", lang: "en", own: "мы", ownLang: "ru", resynced: false,
            isDictionaryWord: { _, _ in false }
        )
        TestRunner.assertNil(vsDecision.core, "'vs' (conflictPairs entry): does not learn")
        TestRunner.assertEqual(vsDecision.rejectReason ?? "MISSING", "conflictPair", "'vs': rejected as conflictPair")

        let myDecision = KeyboardMonitor.learnableCoreDecision(
            from: "мы", lang: "ru", own: "vs", ownLang: "en", resynced: false,
            isDictionaryWord: { _, _ in false }
        )
        TestRunner.assertNil(myDecision.core, "'мы' (conflictPairs entry, ru side): does not learn")
        TestRunner.assertEqual(myDecision.rejectReason ?? "MISSING", "conflictPair", "'мы': rejected as conflictPair")

        // A lone letter stays below the floor — the floor moved from 3 to
        // 2, not to 1.
        let qDecision = KeyboardMonitor.learnableCoreDecision(
            from: "q", lang: "en", own: "й", ownLang: "ru", resynced: false,
            isDictionaryWord: { _, _ in false }
        )
        TestRunner.assertNil(qDecision.core, "'q' (len 1): does not learn")
        TestRunner.assertEqual(qDecision.rejectReason ?? "MISSING", "belowMinLen", "'q': rejected as belowMinLen")
    }
}

/// `LanguageDetector.learnedHitApplies` end to end, against a REAL
/// `WordDictionary`/`LearnedWordsStore` — same fixture pattern as
/// `DetectorExactnessTests`/`LanguageDetectorRingTests`.
enum LearnedVowellessApplyTests {
    static func run() {
        TestRunner.section("LanguageDetector.learnedHitApplies — vowel-less learned tokens (field 08-10.09.2026)")

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for learned-token fixtures")
            return
        }

        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let store = LearnedWordsStore(defaults: UserDefaults(suiteName: "ShortTokenTests.\(UUID().uuidString)")!)
        detector.learnedWordsProvider = { lang in store.activeKeys(lang: lang) }

        // --- 1: empty store → learnedHitApplies is false regardless of length/mixedScript. ---
        TestRunner.assertTrue(
            !detector.learnedHitApplies(core: "bsc", lang: "en"),
            "empty store: learnedHitApplies false (byte-for-byte with the pre-fix guard order)"
        )

        // --- 2: record "bsc":en twice (promotion) → applies, vowel-less and all. ---
        let t0 = Date()
        TestRunner.assertEqual(
            store.recordManualFix(word: "bsc", lang: "en", originApp: nil, at: t0), .recorded,
            "first manual fix: recorded, not yet promoted"
        )
        TestRunner.assertEqual(
            store.recordManualFix(word: "bsc", lang: "en", originApp: nil, at: t0.addingTimeInterval(60)), .promoted,
            "second manual fix within the window: promoted"
        )
        TestRunner.assertTrue(
            detector.learnedHitApplies(core: "bsc", lang: "en"),
            "'bsc' (no vowel at all) applies once promoted — JunkMeter.isClean would have refused this forever"
        )

        // --- 3: end to end through detect() — the SAME keys read as «иыс»
        //        on ru / "bsc" on en, typed on the ru layout, must switch to
        //        en "bsc" now that it's a confirmed learned entry. Priming
        //        context to "en" first (an honest prior English word) is
        //        the realistic field shape — the owner was mid-English-run
        //        when this token landed on the wrong layout — and removes
        //        any dependency on n-gram/frequency arithmetic to prove the
        //        point: a plain unlearned run would need to win the score
        //        race on its own, a learned one only needs to clear
        //        `collisionGap`/`incumbentGap` against non-dictionary «иыс». ---
        let enReverse = ShortTokenFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        guard let bscStrokes = ShortTokenFixtures.keystrokes(for: "bsc", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'bsc': en fixture layout can type every character")
            return
        }
        detector.resetContext()
        guard let helloStrokes = ShortTokenFixtures.keystrokes(for: "hello", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'hello': en fixture layout can type every character")
            return
        }
        _ = detector.detect(keystrokes: helloStrokes, typedLayout: enLayout) // primes previousWordLanguage = "en"

        let ownReading = inputSources.convertKeystrokes(bscStrokes, toLayout: ruLayout)
        switch detector.detect(keystrokes: bscStrokes, typedLayout: ruLayout) {
        case .switchTo(let layout, let word):
            TestRunner.assertEqual(layout.languageCode, "en", "own «\(ownReading)» on ru, learned 'bsc': switches to en")
            TestRunner.assertEqual(word, "bsc", "corrects to 'bsc' exactly")
        case .noSwitch:
            TestRunner.assertTrue(
                false,
                "own «\(ownReading)» on ru, learned 'bsc': expected switchTo(en, \"bsc\") — got noSwitch"
            )
        }
    }
}

/// The write-gate's `ownIsWord` guard (above) stops the PAIR from ever being
/// learned in the first place — this suite proves the INDEPENDENT, older
/// safety net still holds even if a bad pair somehow got into the store by
/// another route (manual JSON import, a future write path, hand-edited
/// defaults): the native-context incumbent lock in `detect()` itself.
enum LearnedTwoLetterIncumbentTests {
    static func run() {
        TestRunner.section("LanguageDetector.detect — native-context incumbent lock beats a bad learned 2-letter entry")

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the incumbent-lock fixture")
            return
        }

        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let store = LearnedWordsStore(defaults: UserDefaults(suiteName: "ShortTokenTests.\(UUID().uuidString)")!)
        detector.learnedWordsProvider = { lang in store.activeKeys(lang: lang) }

        let ruReverse = ShortTokenFixtures.reverseMap(for: ruLayout, inputSources: inputSources)
        guard let onStrokes = ShortTokenFixtures.keystrokes(for: "он", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«он»: ru fixture layout can type every character")
            return
        }

        // The SAME two physical keys, read on en — recorded+promoted by
        // hand, bypassing the write gate entirely (simulating "a bad pair
        // got in some other way", not this fix's own write path).
        let enReading = inputSources.convertKeystrokes(onStrokes, toLayout: enLayout)
        let t0 = Date()
        store.recordManualFix(word: enReading, lang: "en", originApp: nil, at: t0)
        store.recordManualFix(word: enReading, lang: "en", originApp: nil, at: t0.addingTimeInterval(60))
        TestRunner.assertTrue(
            detector.learnedHitApplies(core: enReading, lang: "en"),
            "sanity: «\(enReading)»:en is genuinely promoted before the incumbent-lock check below"
        )

        // Prime an established ru context (an honest prior ru word), then
        // type «он» honestly. The incumbent lock fires unconditionally on
        // "current layout's own reading is a dictionary word AND the
        // established context already is that language" — no score race
        // against the learned entry needed.
        detector.resetContext()
        guard let privetStrokes = ShortTokenFixtures.keystrokes(for: "привет", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "«привет»: ru fixture layout can type every character")
            return
        }
        _ = detector.detect(keystrokes: privetStrokes, typedLayout: ruLayout) // primes previousWordLanguage = "ru"

        switch detector.detect(keystrokes: onStrokes, typedLayout: ruLayout) {
        case .noSwitch:
            TestRunner.assertTrue(true, "«он» under ru-context stays noSwitch — incumbent lock holds despite the learned «\(enReading)»:en entry")
        case .switchTo:
            TestRunner.assertTrue(
                false,
                "«он» under ru-context switched away to «\(enReading)»:en — incumbent lock did NOT hold"
            )
        }
    }
}

/// Copied from `DetectorExactnessTests.swift`'s `private enum
/// DetectorExactnessFixtures` (file-private there, unreachable from this
/// file) — same two helpers, unchanged, same established precedent.
private enum ShortTokenFixtures {
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
