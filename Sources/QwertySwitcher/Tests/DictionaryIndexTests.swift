#if DEBUG
import Foundation

/// Plan 006 Step 4: `WordDictionary.loadSortedWordsAsync` re-sorts and
/// re-lowercases both bundled word lists on every launch even though
/// CLAUDE.md already records them as "reported already sorted and lowercase
/// by `LC_ALL=C sort -c`, which is NOT Swift's `String <` order — do not
/// rely on that". This guard settles it with the ACTUAL comparator the
/// runtime uses (Swift `<`), not the shell's C-locale byte sort, and is the
/// gate the plan's Step 4 conditions on: if it goes red, the redundant sort
/// and per-line transform stay; if it stays green, it also doubles as the
/// regression guard for having removed them (see
/// `WordDictionary.loadSortedWordsAsync`) — a future dictionary edit that
/// breaks either assumption must turn this red.
enum DictionaryIndexTests {
    static func run() {
        TestRunner.section("Dictionary — bundled word lists (Plan 006 Step 4 sort/lowercase guard)")
        for fileName in ["en_US", "ru_RU"] {
            guard let content = loadFileContent(fileName) else {
                TestRunner.assertTrue(false, "\(fileName).txt is found and readable at a known resource path")
                continue
            }
            let rawLines = content.split(separator: "\n").map(String.init)
            TestRunner.assertTrue(!rawLines.isEmpty, "\(fileName).txt yields non-empty raw lines")

            // Every RAW line (before any transform) already equals its own
            // trimmed+lowercased form — the fact that makes skipping that
            // per-line transform in `loadSortedWordsAsync` safe. Checked
            // against the raw split, not the already-normalized word list
            // below, or this would be tautologically true no matter what
            // the file actually contains.
            let notNormalizedCount = rawLines.filter {
                $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.count
            TestRunner.assertEqual(
                notNormalizedCount, 0,
                "\(fileName).txt raw lines are already trimmed+lowercased — parseWordList's per-line transform is a no-op"
            )

            // The actual word list `parseWordList` produces (mirrored here —
            // it and its resource search path are both private to
            // WordDictionary.swift): trim+lowercase, then the same count>=2
            // filter production uses.
            let words = rawLines.compactMap { line -> String? in
                let word = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return word.count >= 2 ? word : nil
            }
            TestRunner.assertTrue(!words.isEmpty, "\(fileName).txt yields a non-empty word list")

            // words == words.sorted() (Swift `<`) — done without ever
            // printing the ~350K-entry arrays on failure.
            let sorted = words.sorted()
            var firstMismatch = -1
            for i in 0..<min(words.count, sorted.count) where words[i] != sorted[i] {
                firstMismatch = i
                break
            }
            let isSorted = firstMismatch == -1 && words.count == sorted.count
            let sortMessage = isSorted
                ? "\(fileName).txt is already in Swift `<` sorted order — the redundant runtime sort can be skipped"
                : "\(fileName).txt is already in Swift `<` sorted order (first mismatch at index \(firstMismatch))"
            TestRunner.assertTrue(isSorted, sortMessage)

            // No duplicates.
            let uniqueCount = Set(words).count
            TestRunner.assertEqual(uniqueCount, words.count, "\(fileName).txt has no duplicate entries")
        }
    }

    private static func loadFileContent(_ fileName: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dictionaries/\(fileName).txt"),
            Bundle.main.resourceURL?.appendingPathComponent("Dictionaries/\(fileName).txt"),
        ]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { continue }
            return content
        }
        return nil
    }
}
#endif
