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

struct SentenceStartTracker {
    private(set) var shouldCapitalizeNextWord = false

    mutating func consumeForWord() -> Bool {
        defer { shouldCapitalizeNextWord = false }
        return shouldCapitalizeNextWord
    }

    mutating func observeBoundary(_ trailing: String?) {
        guard let last = trailing?.last else { return }
        shouldCapitalizeNextWord = ".!?".contains(last)
    }

    mutating func reset() {
        shouldCapitalizeNextWord = false
    }
}
