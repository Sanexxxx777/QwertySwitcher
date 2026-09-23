#if DEBUG
import Foundation

/// Plan 009, Step 4: pins every detector constant/table that exists in BOTH
/// `LanguageDetector.swift` and `Scripts/research/false_switch_sim.py` to the
/// same value. Threshold decisions get made from the Python port's numbers
/// ("what would this cost/save in the field") — a silent drift here means
/// the next decision is calibrated against a DIFFERENT algorithm than what
/// ships. Same `#filePath`-reading precedent as `BigramTablesTests`
/// (`BigramThresholdPortSyncTests` in particular), but unlike that suite an
/// unreadable Python file FAILS here rather than skipping: this suite's
/// entire job is catching drift, so silently passing when it cannot even
/// read one side would defeat the point (plan 009, Step 4).
///
/// Pairs covered (found by reading both files in full):
///   1. `contextBias`   (LanguageDetector.swift) == `CONTEXT_BIAS`   (false_switch_sim.py)
///   2. `collisionGap`  (LanguageDetector.swift) == `COLLISION_GAP`  (false_switch_sim.py)
///   3. `incumbentGap`  (LanguageDetector.swift) == `INCUMBENT_GAP`  (false_switch_sim.py)
///   4. `oneLetterWords["ru"/"en"]` == `ONE_LETTER["ru"/"en"]`
///   5. `twoLetterWords["ru"/"en"]` == `TWO_LETTER["ru"/"en"]`
///   6. `conflictPairs`             == `CONFLICT_PAIRS`
/// This test never changes a value on either side — a mismatch is reported
/// via `assertEqual`'s failure message and left for the owner to resolve.
enum PortParityTests {
    static func run() {
        TestRunner.section("Port parity — LanguageDetector.swift constants/tables vs false_switch_sim.py")

        guard let swiftText = readSwiftSource() else {
            TestRunner.assertTrue(false, "Core/LanguageDetector.swift not readable — port parity cannot be verified")
            return
        }
        guard let pyText = readPythonSource() else {
            TestRunner.assertTrue(false, "Scripts/research/false_switch_sim.py not readable — port parity cannot be verified")
            return
        }

        assertIntPairEqual(
            swiftMarker: "private let contextBias = ", pyMarker: "CONTEXT_BIAS = ",
            swiftText: swiftText, pyText: pyText, name: "contextBias/CONTEXT_BIAS"
        )
        assertIntPairEqual(
            swiftMarker: "private let collisionGap = ", pyMarker: "COLLISION_GAP = ",
            swiftText: swiftText, pyText: pyText, name: "collisionGap/COLLISION_GAP"
        )
        assertIntPairEqual(
            swiftMarker: "private let incumbentGap = ", pyMarker: "INCUMBENT_GAP = ",
            swiftText: swiftText, pyText: pyText, name: "incumbentGap/INCUMBENT_GAP"
        )

        // oneLetterWords / ONE_LETTER — scope to each declaration first (both
        // "ru"/"en" keys appear elsewhere in both files — a `case "ru":` in
        // LanguageDetector.swift, a frequency-table entry in the Python file
        // — so an unscoped search could silently match the wrong table).
        guard let swiftOneLetter = declBlock(
            swiftText, start: "private static let oneLetterWords: [String: Set<Character>] = [",
            end: "/// Same rationale as"
        ) else {
            TestRunner.assertTrue(false, "oneLetterWords declaration not found in LanguageDetector.swift — test needs updating")
            return
        }
        guard let pyOneLetter = declBlock(pyText, start: "ONE_LETTER = {", end: "TWO_LETTER = {") else {
            TestRunner.assertTrue(false, "ONE_LETTER declaration not found in false_switch_sim.py — test needs updating")
            return
        }
        assertLanguageTablesEqual(swiftOneLetter, pyOneLetter, swiftOpen: "[", swiftClose: "]", pyOpen: "{", pyClose: "}", name: "oneLetterWords/ONE_LETTER")

        // twoLetterWords / TWO_LETTER.
        guard let swiftTwoLetter = declBlock(
            swiftText, start: "private static let twoLetterWords: [String: Set<String>] = [",
            end: "/// Conflict pairs:"
        ) else {
            TestRunner.assertTrue(false, "twoLetterWords declaration not found in LanguageDetector.swift — test needs updating")
            return
        }
        guard let pyTwoLetter = declBlock(pyText, start: "TWO_LETTER = {", end: "CONFLICT_PAIRS = {") else {
            TestRunner.assertTrue(false, "TWO_LETTER declaration not found in false_switch_sim.py — test needs updating")
            return
        }
        assertLanguageTablesEqual(swiftTwoLetter, pyTwoLetter, swiftOpen: "[", swiftClose: "]", pyOpen: "{", pyClose: "}", name: "twoLetterWords/TWO_LETTER")

        // conflictPairs / CONFLICT_PAIRS — a flat ru-word -> en-token map,
        // not keyed by language.
        guard let swiftConflict = declBlock(
            swiftText, start: "private static let conflictPairs: [String: String] = [",
            end: "private func scoreWord("
        ) else {
            TestRunner.assertTrue(false, "conflictPairs declaration not found in LanguageDetector.swift — test needs updating")
            return
        }
        guard let pyConflictLine = pyText.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("CONFLICT_PAIRS = {") }) else {
            TestRunner.assertTrue(false, "CONFLICT_PAIRS declaration not found in false_switch_sim.py — test needs updating")
            return
        }
        TestRunner.assertEqual(
            stringDict(swiftConflict), stringDict(String(pyConflictLine)),
            "conflictPairs (Swift) == CONFLICT_PAIRS (Python)"
        )
    }

    // MARK: - File access

    private static func readSwiftSource() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/LanguageDetector.swift")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func readPythonSource() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .deletingLastPathComponent()      // Sources/
            .deletingLastPathComponent()      // <repo root>
            .appendingPathComponent("Scripts/research/false_switch_sim.py")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Extraction helpers

    /// The integer literal immediately following `marker` (e.g. `"private
    /// let contextBias = "` -> `5` out of `private let contextBias = 5`).
    private static func intAfter(_ marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func assertIntPairEqual(swiftMarker: String, pyMarker: String, swiftText: String, pyText: String, name: String) {
        let swiftValue = intAfter(swiftMarker, in: swiftText)
        let pyValue = intAfter(pyMarker, in: pyText)
        TestRunner.assertTrue(swiftValue != nil, "\(name): Swift side found")
        TestRunner.assertTrue(pyValue != nil, "\(name): Python side found")
        TestRunner.assertEqual(swiftValue ?? -1, pyValue ?? -2, "\(name) values match")
    }

    /// Text strictly between the first occurrence of `start` and the next
    /// occurrence of `end` after it — used to scope a search to one
    /// declaration so an identically-named key elsewhere in the file (a
    /// `case "ru":`, an unrelated table) can never be picked up instead.
    private static func declBlock(_ text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let tail = text[startRange.upperBound...]
        guard let endRange = tail.range(of: end) else { return nil }
        return String(tail[..<endRange.lowerBound])
    }

    /// The raw content between the first `open`/`close` pair that follows
    /// `"<lang>":` inside `text` — e.g. for `"ru": ["а", "и"]`, returns
    /// `"а", "и"`. Both source tables are flat (no nested brackets inside a
    /// language's own list), so the first matching close is exact.
    private static func languageArrayContent(_ lang: String, in text: String, open: Character, close: Character) -> String? {
        guard let keyRange = text.range(of: "\"\(lang)\":") else { return nil }
        let afterKey = text[keyRange.upperBound...]
        guard let openIdx = afterKey.firstIndex(of: open) else { return nil }
        let afterOpen = afterKey[afterKey.index(after: openIdx)...]
        guard let closeIdx = afterOpen.firstIndex(of: close) else { return nil }
        return String(afterOpen[..<closeIdx])
    }

    /// All double-quoted tokens in `text` (e.g. `"а", "и", "в"` -> `{"а",
    /// "и", "в"}`) — a manual quote-split rather than a regex, since none of
    /// these literals contain an escaped quote.
    private static func quotedTokens(_ text: String) -> Set<String> {
        let parts = text.components(separatedBy: "\"")
        var result: Set<String> = []
        var i = 1
        while i < parts.count {
            result.insert(parts[i])
            i += 2
        }
        return result
    }

    /// All `"key": "value"` pairs in `text` (used for `conflictPairs`, a
    /// flat map rather than a per-language table).
    private static func stringDict(_ text: String) -> [String: String] {
        let parts = text.components(separatedBy: "\"")
        // parts alternates literal/quoted; a `"key": "value"` pair puts key
        // and value two quoted-slots apart with exactly one separator (": ")
        // between them.
        var result: [String: String] = [:]
        var i = 1
        while i + 2 < parts.count {
            let betweenKeyAndValue = parts[i + 1]
            if betweenKeyAndValue.trimmingCharacters(in: .whitespaces) == ":" {
                result[parts[i]] = parts[i + 2]
                i += 4
            } else {
                i += 2
            }
        }
        return result
    }

    private static func assertLanguageTablesEqual(
        _ swiftBlock: String, _ pyBlock: String,
        swiftOpen: Character, swiftClose: Character, pyOpen: Character, pyClose: Character,
        name: String
    ) {
        for lang in ["ru", "en"] {
            guard let swiftContent = languageArrayContent(lang, in: swiftBlock, open: swiftOpen, close: swiftClose) else {
                TestRunner.assertTrue(false, "\(name)[\(lang)]: Swift side not found — test needs updating")
                continue
            }
            guard let pyContent = languageArrayContent(lang, in: pyBlock, open: pyOpen, close: pyClose) else {
                TestRunner.assertTrue(false, "\(name)[\(lang)]: Python side not found — test needs updating")
                continue
            }
            TestRunner.assertEqual(quotedTokens(swiftContent), quotedTokens(pyContent), "\(name)[\(lang)] values match")
        }
    }
}
#endif
