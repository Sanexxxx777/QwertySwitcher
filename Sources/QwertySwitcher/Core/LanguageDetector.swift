import Foundation
import AppKit

final class LanguageDetector {
    private let dictionary: WordDictionary
    let inputSourceManager: InputSourceManager
    private let prefsService: PreferencesService
    private let ngramAnalyzer = NGramAnalyzer()
    private let wordFrequency = WordFrequency()

    private var previousWordLanguage: String?
    /// Was 15 — LARGER than the `collisionGap` below, which meant the language
    /// of the previous word alone could manufacture a "clear winner" out of a
    /// tie. Harmless while words were letters-only; once punctuation joined the
    /// run it became an English-corrupting bug: "key." renders as the real
    /// Russian word "луню", scoring 88 against English's 91 — a 3-point gap the
    /// collision gate holds — until +15 of context bias pushes it to 103 and
    /// the gate opens. Context is a hint, so it must never on its own clear the
    /// bar that exists to demand a decisive win.
    private let contextBias = 5
    private let collisionGap = 10
    /// Margin required to overrule text that is already a valid word in the
    /// user's current layout. Deliberately far above `collisionGap`: the two
    /// outcomes are not equally bad.
    private let incumbentGap = 25

    private static let skipPatterns: [NSRegularExpression] = {
        let patterns = [
            #"^\d+$"#,                          // numbers
            #"^0x[0-9a-fA-F]+$"#,               // hex
            #"^[a-zA-Z_]\w*[A-Z]\w*$"#,         // camelCase
            #"^[a-zA-Z_]+_[a-zA-Z_]+$"#,        // snake_case
            #"^https?://"#,                      // URLs
            #"^[\w.]+@[\w.]+"#,                  // emails
            #"^[/~][\w/.]+"#,                    // unix paths
            #"^\.[a-z]+"#,                       // extensions
            #"^[A-Z]{2,}$"#,                     // ACRONYMS
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    init(dictionary: WordDictionary, inputSourceManager: InputSourceManager,
         prefsService: PreferencesService) {
        self.dictionary = dictionary
        self.inputSourceManager = inputSourceManager
        self.prefsService = prefsService
    }

    var activeLayouts: [KeyboardLayout] {
        inputSourceManager.resolvedActiveLayouts(preferredIDs: prefsService.activeLayoutIDs)
    }

    func detect(keycodes: [UInt16]) -> DetectionResult {
        detect(keystrokes: keycodes.map { BufferedKeystroke(keycode: $0, flags: []) })
    }

    /// - Parameter typedLayout: the layout `keystrokes` were ACTUALLY typed
    ///   on, when known. Callers reusing raw keycodes captured earlier
    ///   (Double Shift's buffer/history fallback) must pass it explicitly —
    ///   the active layout can drift between typing a word and acting on it
    ///   later (manual switch, another correction), and defaulting to
    ///   "whatever is active now" silently scrambles the swap direction (see
    ///   CLAUDE.md "марже" bug). Omitted only by the live-typing callers
    ///   (`processCurrentWord`/`tryInstantCorrection`), where the word is
    ///   still being typed and the active layout IS the typed layout.
    func detect(keystrokes: [BufferedKeystroke], typedLayout: KeyboardLayout? = nil) -> DetectionResult {
        guard let currentLayout = typedLayout ?? inputSourceManager.currentLayout else { return .noSwitch }
        let layouts = activeLayouts
        guard layouts.count >= 2 else { return .noSwitch }
        guard layouts.contains(where: { $0.id == currentLayout.id }) else { return .noSwitch }

        let currentText = inputSourceManager.convertKeystrokes(keystrokes, toLayout: currentLayout)
        if Self.shouldSkip(currentText) { return .noSwitch }

        var candidates: [(layout: KeyboardLayout, word: String, score: Int, inDictionary: Bool)] = []

        for layout in layouts {
            // A run can hold keys that are punctuation in one alphabet and
            // letters in the other (`;`=ж, `,`=б, `.`=ю, `[`=х, `]`=ъ, `'`=э).
            // Score only the LETTER CORE, but replace the whole run — and try
            // both readings of a trailing ambiguous key, because "ghbdtn." is
            // "привет" + "." and NOT the non-word "приветю".
            let readings = projections(keystrokes, to: layout, asTyped: currentText)
            guard let best = readings.max(by: { scoreWord($0.core, language: layout.languageCode)
                                                 < scoreWord($1.core, language: layout.languageCode) })
            else { continue }
            let word = best.replacement
            let core = best.core
            guard !word.isEmpty, !core.isEmpty else { continue }
            if Self.isMixedScript(core) { continue }

            let dictionaryScore = scoreWord(core, language: layout.languageCode)
            let inDictionary = dictionaryScore > 0
            var score = dictionaryScore

            // N-gram bonus/penalty — on the core, not the run: a trailing "."
            // or "," is not evidence about which alphabet the WORD is in.
            let ngramScore = ngramAnalyzer.score(core, language: layout.languageCode)
            score += ngramScore

            // Word frequency bonus
            score += wordFrequency.bonus(core, language: layout.languageCode)

            // Context bias
            if score > 0, layout.languageCode == previousWordLanguage {
                score += contextBias
            }

            // Current layout tie-breaker
            if score > 0, layout.id == currentLayout.id {
                score += 5
            }

            if score > 0 {
                candidates.append((layout, word, score, inDictionary))
            }
        }

        guard !candidates.isEmpty else {
            previousWordLanguage = currentLayout.languageCode
            return .noSwitch
        }

        candidates.sort { $0.score > $1.score }
        let best = candidates[0]
        previousWordLanguage = best.layout.languageCode

        if best.layout.id == currentLayout.id { return .noSwitch }

        // Rewriting text the user already typed correctly is the one failure
        // this feature must not have ("промахи нам не надо" — 05.08.2026, a
        // correct 9-letter Russian word was flipped to latin on a trailing
        // period; log 08:24:05 "correction: ru→en len=9 trig=."). The hole:
        // `scoreWord` returns 80-100 for a dictionary hit and 0 for a miss, so
        // a correctly-typed word that simply isn't in our 714K list scores 0
        // and never becomes a candidate at all — leaving the other layout's
        // gibberish as the SOLE candidate, where the collision gate below
        // (which needs two) can't touch it, and a handful of n-gram points
        // wins unopposed. So: the winner must be a real word of the target
        // language. Cost is a missed correction (recoverable — Double Shift),
        // never corrupted text (not recoverable without noticing it first).
        guard best.inDictionary else { return .noSwitch }

        // Collision: need clear winner
        if candidates.count >= 2 && (candidates[0].score - candidates[1].score) < collisionGap {
            return .noSwitch
        }

        // Asymmetric burden of proof. If what the user typed ALREADY reads as a
        // real word in the language of their current layout, they were almost
        // certainly typing that word — and overwriting it is the expensive
        // mistake, while skipping is the cheap one (Double Shift recovers it).
        // Without this, English words whose latin keys spell a valid Russian
        // word lose on a few n-gram points: "key." → "луню", "bye." → "иную",
        // "next." → "тучею" (58 such collisions counted in the bundled
        // dictionaries). A plain gap can't separate them — both sides are
        // genuine dictionary hits — so the incumbent gets a wide moat instead.
        if let incumbent = candidates.first(where: { $0.layout.id == currentLayout.id }),
           incumbent.inDictionary,
           best.score - incumbent.score < incumbentGap {
            return .noSwitch
        }

        return .switchTo(layout: best.layout, correctedWord: best.word)
    }

    func lastConvertedWord(keycodes: [UInt16]) -> String? {
        lastConvertedWord(keystrokes: keycodes.map { BufferedKeystroke(keycode: $0, flags: []) })
    }

    func lastConvertedWord(keystrokes: [BufferedKeystroke]) -> String? {
        guard let current = inputSourceManager.currentLayout else { return nil }
        return inputSourceManager.convertKeystrokes(keystrokes, toLayout: current)
    }

    func currentRussianLayout() -> KeyboardLayout? {
        inputSourceManager.currentLayout?.isRussian == true ? inputSourceManager.currentLayout : nil
    }

    /// Resolves what Double Shift's buffer/history swap should do with
    /// `keystrokes` typed on `typedLayout`: prefers the scored `detect()`
    /// result (same calibration as every other correction), but falls back
    /// to a FORCED swap to "the other" active layout when the scorer sees no
    /// reason to switch away from the current interpretation (`.noSwitch`) —
    /// typically because it's already a good word. That forced fallback is
    /// what makes a SECOND, immediate Double Shift on a word the first press
    /// just converted toggle it back predictably, instead of falling through
    /// to the caret-word/Undo paths (see CLAUDE.md Double Shift toggle bug).
    /// Returns nil when there's nothing sensible to do: fewer than 2 active
    /// layouts, `typedLayout` isn't one of them, or the forced fallback
    /// produces empty text.
    func swapTarget(
        keystrokes: [BufferedKeystroke], typedLayout: KeyboardLayout
    ) -> (layout: KeyboardLayout, word: String)? {
        let layouts = activeLayouts
        guard layouts.count >= 2, layouts.contains(where: { $0.id == typedLayout.id }) else { return nil }

        switch detect(keystrokes: keystrokes, typedLayout: typedLayout) {
        case .switchTo(let layout, let word):
            return (layout, word)
        case .noSwitch:
            guard let other = layouts.first(where: { $0.id != typedLayout.id }) else { return nil }
            let word = inputSourceManager.convertKeystrokes(keystrokes, toLayout: other)
            guard !word.isEmpty else { return nil }
            return (other, word)
        }
    }

    func resetContext() { previousWordLanguage = nil }

    // MARK: - Multi-level scoring (Dictionary + SpellCheck + N-grams + Frequency)

    /// One reading of a run under a candidate layout: which part is the word
    /// (`core`, the only thing worth scoring) and what the whole run becomes on
    /// screen if this layout wins (`replacement`).
    private struct Projection {
        let core: String
        let replacement: String
    }

    /// Splits a rendered run into `[leading non-letters][core][trailing non-letters]`.
    /// Returns nil when the letters are INTERRUPTED by a non-letter — two cores
    /// mean this is not one word ("model/path", "a;b", "--flag=value"), and
    /// that single rule is what keeps shell commands safe.
    private static func core(of rendered: String) -> String? {
        let core = rendered.drop(while: { !$0.isLetter })
            .prefix(while: { $0.isLetter })
        guard !core.isEmpty else { return nil }
        let rest = rendered.drop(while: { !$0.isLetter }).dropFirst(core.count)
        guard !rest.contains(where: { $0.isLetter }) else { return nil }
        return String(core)
    }

    /// Up to two readings per layout. The second exists because an ambiguous
    /// trailing key is genuinely ambiguous: typing "ghbdtn." means "привет."
    /// (a word plus a full stop), not the non-word "приветю" — but typing
    /// "nfr;t" means "также", where the very same class of key IS a letter.
    /// Only the dictionary can tell them apart, so we score both and keep the
    /// better one.
    private func projections(
        _ keystrokes: [BufferedKeystroke],
        to layout: KeyboardLayout,
        // Rendered ONCE by the caller and passed in: it doesn't depend on the
        // candidate layout, and every `convertKeystrokes` is a `UCKeyTranslate`
        // per character. This runs on each word boundary, so the difference
        // between 5 and 3 renders per word is free to take.
        asTyped: String
    ) -> [Projection] {
        var result: [Projection] = []

        let whole = inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        if let core = Self.core(of: whole) {
            result.append(Projection(core: core, replacement: whole))
        }

        // Trailing keys that the user SAW as punctuation while typing: peel them
        // off, convert only the head, and leave them exactly as typed.
        let trailingPunct = asTyped.reversed().prefix(while: { !$0.isLetter }).count
        if trailingPunct > 0, trailingPunct < keystrokes.count {
            let head = Array(keystrokes.dropLast(trailingPunct))
            let tail = String(asTyped.suffix(trailingPunct))
            let headRendered = inputSourceManager.convertKeystrokes(head, toLayout: layout)
            if let core = Self.core(of: headRendered) {
                result.append(Projection(core: core, replacement: headRendered + tail))
            }
        }

        return result
    }

    /// The complete set of one-letter words, spelled out rather than looked up.
    /// The Bloom filter cannot be trusted at this length: with ~0.5% false
    /// positives and an alphabet of only 59 candidates, "б", "ж" and "ъ" would
    /// eventually pass as words and start rewriting text. The real list is
    /// short, closed and unambiguous, so it belongs in the code.
    private static let oneLetterWords: [String: Set<Character>] = [
        "ru": ["а", "и", "в", "к", "о", "с", "у", "я"],
        "en": ["a", "i"]
    ]

    private func scoreWord(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
        if lowered.count == 1 {
            guard let letter = lowered.first,
                  Self.oneLetterWords[language]?.contains(letter) == true else { return 0 }
            // Below the 84-100 a dictionary hit scores: a one-letter word is
            // real, but it is also the weakest possible evidence, and it has
            // to lose to any longer word competing for the same run.
            return 70
        }
        guard lowered.count >= 2 else { return 0 }

        // BloomFilter-only membership check (pure in-memory, no IPC) — this
        // runs synchronously on every word boundary (space/punctuation) for
        // every candidate layout, inside the CGEventTap callback.
        // `dictionary.contains`/`isSpellCheckerValid` used to be called here,
        // confirming via `NSSpellChecker.checkSpelling` — a call that can
        // block for 100+ms (macOS spell-checking IPC), which is exactly what
        // disabled the event tap and dropped keystrokes during normal typing
        // (CLAUDE.md perf audit). `mightContain` accepts the BloomFilter's
        // ~0.5% false-positive rate instead: the cost is an occasional missed
        // correction (falls through to `.noSwitch`, user can still Double
        // Shift manually) or a slightly wider net for a genuinely valid word
        // outside the bundled 714K list — never a blocked keystroke.
        if dictionary.mightContain(lowered, language: language) {
            let lengthBonus = min(20, lowered.count * 2)
            return 80 + lengthBonus  // 84-100
        }

        return 0
    }

    static func shouldSkip(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for p in skipPatterns {
            if p.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    static func isMixedScript(_ text: String) -> Bool {
        var hasCyrillic = false, hasLatin = false
        for s in text.unicodeScalars {
            if (0x0400...0x04FF).contains(s.value) { hasCyrillic = true }
            if (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) { hasLatin = true }
            if hasCyrillic && hasLatin { return true }
        }
        return false
    }

    /// Best-guess source language of already-rendered `text` (AX selection,
    /// clipboard, word before caret) from its OWN characters — Cyrillic vs
    /// Latin letters, majority wins on mixed content. Never looks at the
    /// active layout: for ready-made text there are no original keystrokes,
    /// and the active layout may have nothing to do with what produced this
    /// text (see CLAUDE.md "марже" bug). Returns nil when the text carries no
    /// Cyrillic/Latin letters at all (pure digits/punctuation/emoji) —
    /// callers must treat that as "can't tell", never guess.
    static func dominantScriptLanguageCode(_ text: String) -> String? {
        var cyrillic = 0, latin = 0
        for s in text.unicodeScalars {
            if (0x0400...0x04FF).contains(s.value) { cyrillic += 1 }
            else if (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) { latin += 1 }
        }
        guard cyrillic > 0 || latin > 0 else { return nil }
        return cyrillic >= latin ? "ru" : "en"
    }
}
