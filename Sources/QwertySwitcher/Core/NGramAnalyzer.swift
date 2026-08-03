import Foundation

/// N-gram based language scoring (like Caramba/Punto Switcher)
/// Uses forbidden bigrams — character combinations impossible in a language
final class NGramAnalyzer {

    // Forbidden bigrams: if ANY of these appear in a word, it's NOT this language
    private let forbiddenRU: Set<String> = [
        "ьъ","ъь","ъъ","ыъ","ъы","эъ","ъэ","юъ","ъю","яъ","ъя",
        "ьь","ыь","ъё","ёъ","жщ","щж","шщ","щш","цщ","щц",
        "гщ","щг","фщ","щф","ыы","ыэ","эы","ьы","ыь","ъй",
        "йъ","ьй","щы","ыщ","щэ","эщ","шы","ышь","чщ","щч",
    ]

    private let forbiddenEN: Set<String> = [
        "qx","xq","qz","zq","jx","xj","jq","qj","vq","qv",
        "zx","xz","bx","xb","kx","xk","wx","xw","vx","xv",
        "jz","zj","fq","qf","gx","xg","hx","xh","mx","xm",
        "px","xp","bq","qb","wq","qw","vj","jv","zg","gz",
    ]

    // Common bigrams: high frequency = more confidence
    private let commonRU: [String: Int] = [
        "ст":9,"но":9,"то":9,"на":8,"ен":8,"ни":8,"ов":8,"ко":8,
        "ро":8,"ра":8,"по":8,"ал":8,"ор":8,"пр":8,"ер":8,"ре":8,
        "не":8,"об":7,"ос":7,"ол":7,"от":7,"ли":7,"ка":7,"ом":7,
        "ел":7,"ан":7,"ти":7,"ри":7,"ве":7,"ой":7,"да":7,"ат":7,
        "ит":7,"ло":7,"го":7,"ва":6,"ле":6,"та":6,"ет":6,"ки":6,
    ]

    private let commonEN: [String: Int] = [
        "th":9,"he":9,"in":8,"er":8,"an":8,"re":8,"on":8,"at":8,
        "en":8,"nd":8,"ti":7,"es":7,"or":7,"te":7,"of":7,"ed":7,
        "is":7,"it":7,"al":7,"ar":7,"st":7,"to":7,"nt":7,"ng":7,
        "se":7,"ha":6,"as":6,"ou":6,"io":6,"le":6,"ve":6,"co":6,
        "me":6,"de":6,"hi":6,"ri":6,"ro":6,"ic":6,"ne":6,"ea":6,
    ]

    /// Score word by n-gram analysis. Returns 0-40 bonus score.
    func score(_ word: String, language: String) -> Int {
        let lowered = word.lowercased()
        guard lowered.count >= 2 else { return 0 }

        let bigrams = extractBigrams(lowered)
        guard !bigrams.isEmpty else { return 0 }

        let forbidden = language == "ru" ? forbiddenRU : forbiddenEN
        let common = language == "ru" ? commonRU : commonEN

        // Check forbidden — if ANY forbidden bigram found, strong negative
        for bg in bigrams {
            if forbidden.contains(bg) { return -50 }
        }

        // Score common bigrams
        var totalScore = 0
        var matches = 0
        for bg in bigrams {
            if let s = common[bg] {
                totalScore += s
                matches += 1
            }
        }

        // Normalize: percentage of recognized bigrams × score
        let ratio = Double(matches) / Double(bigrams.count)
        return Int(ratio * Double(min(totalScore, 40)))
    }

    private func extractBigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        var result: [String] = []
        for i in 0..<(chars.count - 1) {
            result.append(String(chars[i...i+1]))
        }
        return result
    }
}
