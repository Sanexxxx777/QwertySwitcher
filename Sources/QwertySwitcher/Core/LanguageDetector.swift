import Foundation
import AppKit

final class LanguageDetector {
    private let dictionary: WordDictionary
    let inputSourceManager: InputSourceManager
    private let prefsService: PreferencesService
    private let ngramAnalyzer = NGramAnalyzer()
    private let wordFrequency = WordFrequency()

    private var previousWordLanguage: String?
    private let contextBias = 15

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
            let word = inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
            guard !word.isEmpty else { continue }
            if Self.isMixedScript(word) { continue }

            let dictionaryScore = scoreWord(word, language: layout.languageCode)
            let inDictionary = dictionaryScore > 0
            var score = dictionaryScore

            // N-gram bonus/penalty
            let ngramScore = ngramAnalyzer.score(word, language: layout.languageCode)
            score += ngramScore

            // Word frequency bonus
            score += wordFrequency.bonus(word, language: layout.languageCode)

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

        // Collision: need clear winner (gap >= 10)
        if candidates.count >= 2 && (candidates[0].score - candidates[1].score) < 10 {
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

    private func scoreWord(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
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
