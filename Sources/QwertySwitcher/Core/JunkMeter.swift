import Foundation

/// Junk-override principle (owner, 16.08.2026 TODO in CLAUDE.md): "русский
/// коряво написан ⇒ я пишу на английском; программа должна это понимать" —
/// the junk-ness of the CURRENT reading is a signal to convert, standing on
/// its own next to the dictionary. `LanguageDetector` is the only caller;
/// pulled out here so the pure math is independently testable without a
/// live `WordDictionary`/`InputSourceManager`.
///
/// Honest Python port and corpus-verified numbers:
/// Scripts/research/false_switch_sim.py `junk`/`clean` — keep both in sync.
enum JunkMeter {
    private static let ruVowels: Set<Character> = Set("аеёиоуыэюя")
    private static let enVowels: Set<Character> = Set("aeiouy")

    private static func vowels(for language: String) -> Set<Character> {
        language == "ru" ? ruVowels : enVowels
    }

    /// Мусорность прочтения: нет ни одной гласной ИЛИ есть биграмма, не
    /// встречающаяся ни в одном словарном слове языка (`possibleBigrams` —
    /// see `WordDictionary.possibleBigrams(language:)`). Words shorter than
    /// 2 characters are never junk — too short for either signal to mean
    /// anything.
    static func isJunk(_ word: String, language: String, possibleBigrams: Set<String>) -> Bool {
        let lowered = word.lowercased()
        let chars = Array(lowered)
        guard chars.count >= 2 else { return false }
        let ownVowels = vowels(for: language)
        guard chars.contains(where: { ownVowels.contains($0) }) else { return true }
        for i in 0..<(chars.count - 1) where !possibleBigrams.contains(String(chars[i...i + 1])) {
            return true
        }
        return false
    }

    /// Правдоподобие ЦЕЛИ override: есть гласная И все биграммы возможны.
    static func isClean(_ word: String, language: String, possibleBigrams: Set<String>) -> Bool {
        let lowered = word.lowercased()
        let chars = Array(lowered)
        let ownVowels = vowels(for: language)
        guard chars.contains(where: { ownVowels.contains($0) }) else { return false }
        for i in 0..<(chars.count - 1) where !possibleBigrams.contains(String(chars[i...i + 1])) {
            return false
        }
        return true
    }
}
