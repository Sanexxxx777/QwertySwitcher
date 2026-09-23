import Foundation

enum SmartCaseNormalizer {
    static func normalized(_ word: String, capitalizeSentenceStart: Bool) -> String? {
        let characters = Array(word)
        guard !characters.isEmpty,
              word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return nil
        }

        if capitalizeSentenceStart,
           characters.dropFirst().allSatisfy({ String($0) == String($0).lowercased() }),
           let first = characters.first {
            let replacement = String(first).uppercased() + String(characters.dropFirst())
            if replacement != word { return replacement }
        }

        guard characters.count >= 3,
              String(characters[0]) == String(characters[0]).uppercased(),
              String(characters[1]) == String(characters[1]).uppercased(),
              characters.dropFirst(2).allSatisfy({ String($0) == String($0).lowercased() }) else {
            return nil
        }
        let replacement = String(characters[0]) + String(characters.dropFirst()).lowercased()
        return replacement == word ? nil : replacement
    }
}

/// "Capitalize the next word" = a word ended with `.!?` AND a real gap
/// (Space/Enter/Tab) followed it AND nothing but that gap sits between the
/// punctuation and the next word. Field log 21–23.09.2026, 4 wrong of 22
/// (examples below are synthetic, same shapes): "узна.Т" (RU "." typed
/// instead of "ю" mid-word, no gap), "Готово. 5 Минут" (the sentence started
/// with a number), "спасибО." and "готово Теперь." (the period was
/// backspaced away). Missing a capitalization is the accepted safe
/// direction; inventing one is not.
struct SentenceStartTracker {
    private var sentenceEnded = false
    private var gapAfterEnd = false

    var shouldCapitalizeNextWord: Bool { sentenceEnded && gapAfterEnd }

    /// A word is starting to be judged; `leadHasDigit` = digits typed right
    /// before it ("5км") — then the sentence started with the number.
    mutating func consumeForWord(leadHasDigit: Bool = false) -> Bool {
        defer { reset() }
        return shouldCapitalizeNextWord && !leadHasDigit
    }

    /// A non-empty word just ended with `trailing`.
    mutating func observeBoundary(_ trailing: String?) {
        guard let last = trailing?.last else { return }
        sentenceEnded = ".!?".contains(last)
        gapAfterEnd = false
    }

    /// A boundary with no word: the Space right after "Hello." (`isGap`), a
    /// second punctuation mark, or a token of digits ("50 ") — a number
    /// opens the sentence, so the word after it is not its first.
    mutating func observeEmptyBoundary(isGap: Bool, leadHasDigit: Bool) {
        if leadHasDigit { reset(); return }
        if isGap, sentenceEnded { gapAfterEnd = true }
    }

    mutating func reset() {
        sentenceEnded = false
        gapAfterEnd = false
    }
}
