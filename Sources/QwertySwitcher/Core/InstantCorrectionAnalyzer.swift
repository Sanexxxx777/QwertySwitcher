import Foundation

/// Mid-word instant layout correction (Caramba-style): after each newly
/// typed letter, decide whether the word buffered so far is confidently in
/// the WRONG layout and should be corrected immediately instead of waiting
/// for a word boundary (space/punctuation).
///
/// Pure and side-effect free — unlike `LanguageDetector.detect`, it never
/// touches `previousWordLanguage`, so evaluating it once per keystroke
/// cannot pollute the cross-word context bias used by the boundary path.
///
/// Thresholds are calibrated against the `Resources/Dictionaries` corpus —
/// see `InstantCorrectionCorpusTests` in TestRunner.swift, which requires
/// exactly 0 false positives over ~2000 real EN + ~2000 real RU words typed
/// honestly in their own layout. Tighten thresholds here, not the test, if
/// that ever regresses.
final class InstantCorrectionAnalyzer {
    /// Minimum buffered letters before instant correction is even considered.
    static let minLength = 4

    /// A current-language combined score at or below this is treated as
    /// "the text typed so far is not a plausible word in this language".
    static let currentCeiling = 5

    /// The other-language candidate's combined score must clear this floor.
    static let candidateFloor = 35

    /// Minimum score gap required between the candidate and the current text.
    static let margin = 30

    struct Result {
        let layout: KeyboardLayout
        let correctedWord: String
    }

    private let dictionary: WordDictionary
    private let ngramAnalyzer = NGramAnalyzer()
    private let wordFrequency = WordFrequency()

    init(dictionary: WordDictionary) {
        self.dictionary = dictionary
    }

    /// - Parameters:
    ///   - keystrokes: the word buffered so far (physical keycodes).
    ///   - currentLayout: the layout the keystrokes currently display as.
    ///   - otherLayouts: candidate replacement layouts (the rest of the active pair).
    ///   - convert: keystrokes → text under a given layout.
    func evaluate(
        keystrokes: [BufferedKeystroke],
        currentLayout: KeyboardLayout,
        otherLayouts: [KeyboardLayout],
        convert: (KeyboardLayout) -> String
    ) -> Result? {
        guard keystrokes.count >= Self.minLength else { return nil }

        let currentText = convert(currentLayout)
        guard !currentText.isEmpty, !LanguageDetector.shouldSkip(currentText) else { return nil }

        // Junk-gate (field defect 19.08.2026, measured
        // Scripts/research/instant_junk_gate_sim.py `first_instant_fire_gated`):
        // if the OWN reading of the prefix typed so far already looks like a
        // real word by the junk metric — has a vowel AND every bigram is
        // possible in this language (`JunkMeter.isClean`, same test the
        // boundary-path junk-override uses) — instant does not fire at this
        // prefix length. Without this, out-of-dictionary Russian (jargon/
        // typo/name) stays silent on the ru-prefix gate below while an en
        // candidate still clears the floor/margin and wins, flipping the
        // layout mid-word. Stand: 93.5% (ru→en) / 87.5% (en→ru) false
        // switches removed at ~1% hard loss (the rest recovers at the
        // boundary path once the word is a real dictionary word). A junk own
        // reading (no vowel — "работа"=hf,jnf, "привет"=ghbdtn) is untouched,
        // and nil bigrams (prefix index still building) leave the gate
        // silent — never blocking on a guess.
        if let bigrams = dictionary.possibleBigrams(language: currentLayout.languageCode),
           JunkMeter.isClean(currentText, language: currentLayout.languageCode, possibleBigrams: bigrams) {
            return nil
        }

        let current = combinedScore(currentText, language: currentLayout.languageCode)
        // A dictionary/prefix match on the CURRENT side always wins, even if
        // a heuristic n-gram penalty (e.g. a "forbidden" bigram that is
        // actually a legitimate morphological pattern, like ъ+я in Russian)
        // would otherwise drag the total score down. Confirmed real text is
        // never "impossible", no matter what the bigram table thinks.
        guard current.wordLevel == 0, current.total <= Self.currentCeiling else { return nil }

        var best: (layout: KeyboardLayout, word: String, score: Int)?

        for layout in otherLayouts where layout.id != currentLayout.id {
            let candidateText = convert(layout)
            guard !candidateText.isEmpty, !LanguageDetector.isMixedScript(candidateText) else { continue }

            let candidate = combinedScore(candidateText, language: layout.languageCode)
            // Must be independently validated (dictionary / spellcheck / a
            // real prefix) — a raw n-gram score alone is never enough.
            guard candidate.wordLevel > 0 else { continue }
            guard candidate.total >= Self.candidateFloor else { continue }
            guard candidate.total - current.total >= Self.margin else { continue }

            if best == nil || candidate.total > best!.score {
                best = (layout, candidateText, candidate.total)
            }
        }

        guard let winner = best else { return nil }
        return Result(layout: winner.layout, correctedWord: winner.word)
    }

    // MARK: - Scoring (Dictionary(+SpellCheck confirm) / bundled-Prefix + N-gram + Frequency)

    private func wordLevelScore(_ lowered: String, language: String) -> Int {
        // `isSpellCheckerValid`/`contains`'s spellcheck confirmation are
        // deliberately NOT used here — for two independent reasons. (1)
        // macOS's checkSpelling is unreliable for short, unrecognized tokens
        // — it accepts nonsense like "fdef"/"zzzz"/"bbbb" as correctly-spelled
        // English (verified empirically), which would make instant
        // correction misfire on any mid-word text that happens to type those
        // letters. (2) `evaluate` runs on EVERY buffered keystroke once the
        // word reaches `minLength` — calling `NSSpellChecker.checkSpelling`
        // synchronously from there (as `contains` used to) put a 100+ms-worst-
        // case IPC call on essentially every letter of ordinary typing,
        // which is what disabled the event tap and dropped keystrokes
        // (CLAUDE.md perf audit). `mightContain` (bloom-only) and the
        // bundled-dictionary prefix index are both deterministic AND
        // in-memory-only — safe for this hot path.
        if dictionary.mightContain(lowered, language: language) {
            return 80 + min(20, lowered.count * 2) // complete, confirmed word
        }
        if dictionary.isPrefixOfBundledWord(lowered, language: language) {
            return 35 // confident but not-yet-complete prefix of a real word
        }
        return 0
    }

    private func combinedScore(_ word: String, language: String) -> (total: Int, wordLevel: Int) {
        let lowered = word.lowercased()
        guard lowered.count >= 2 else { return (0, 0) }
        let wordLevel = wordLevelScore(lowered, language: language)
        let total = wordLevel
            + ngramAnalyzer.score(lowered, language: language)
            + wordFrequency.bonus(lowered, language: language)
        return (total, wordLevel)
    }
}
