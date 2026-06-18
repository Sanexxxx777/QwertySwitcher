import Foundation
import AppKit

final class LanguageDetector {
    private let dictionary: WordDictionary
    let inputSourceManager: InputSourceManager
    private let ngramAnalyzer = NGramAnalyzer()
    private let wordFrequency = WordFrequency()

    private var previousWordLanguage: String?
    private let contextBias = 15

    private let skipPatterns: [NSRegularExpression] = {
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

    init(dictionary: WordDictionary, inputSourceManager: InputSourceManager) {
        self.dictionary = dictionary
        self.inputSourceManager = inputSourceManager
    }

    func detect(keycodes: [UInt16]) -> DetectionResult {
        guard let currentLayout = inputSourceManager.currentLayout else { return .noSwitch }
        let layouts = inputSourceManager.availableLayouts
        guard layouts.count >= 2 else { return .noSwitch }

        let currentText = inputSourceManager.convertKeycodes(keycodes, toLayout: currentLayout).lowercased()
        if shouldSkip(currentText) { return .noSwitch }

        var candidates: [(layout: KeyboardLayout, word: String, score: Int)] = []

        for layout in layouts {
            let word = inputSourceManager.convertKeycodes(keycodes, toLayout: layout)
            guard !word.isEmpty else { continue }
            if isMixedScript(word) { continue }

            var score = scoreWord(word, language: layout.languageCode)

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
                candidates.append((layout, word, score))
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

        // Collision: need clear winner (gap >= 10)
        if candidates.count >= 2 && (candidates[0].score - candidates[1].score) < 10 {
            return .noSwitch
        }

        return .switchTo(layout: best.layout, correctedWord: best.word)
    }

    func lastConvertedWord(keycodes: [UInt16]) -> String? {
        guard let current = inputSourceManager.currentLayout else { return nil }
        return inputSourceManager.convertKeycodes(keycodes, toLayout: current)
    }

    func currentRussianLayout() -> KeyboardLayout? {
        inputSourceManager.currentLayout?.isRussian == true ? inputSourceManager.currentLayout : nil
    }

    func resetContext() { previousWordLanguage = nil }

    // MARK: - Multi-level scoring (Dictionary + SpellCheck + N-grams + Frequency)

    private func scoreWord(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
        guard lowered.count >= 2 else { return 0 }

        // BloomFilter + SpellChecker confirmation (inside dictionary.contains)
        if dictionary.contains(lowered, language: language) {
            let lengthBonus = min(20, lowered.count * 2)
            return 80 + lengthBonus  // 84-100
        }

        // Pure SpellChecker fallback (word not in our 714K dict but known to macOS)
        if dictionary.mightContain(lowered, language: language) {
            return 60 + min(10, lowered.count)  // 62-70
        }

        return 0
    }

    private func shouldSkip(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for p in skipPatterns {
            if p.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    private func isMixedScript(_ text: String) -> Bool {
        var hasCyrillic = false, hasLatin = false
        for s in text.unicodeScalars {
            if (0x0400...0x04FF).contains(s.value) { hasCyrillic = true }
            if (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) { hasLatin = true }
            if hasCyrillic && hasLatin { return true }
        }
        return false
    }
}
