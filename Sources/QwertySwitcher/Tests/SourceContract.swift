#if DEBUG
import Foundation

/// The one reader for every source-contract guard (tests that pin code STRUCTURE by reading Swift
/// as text, because driving the real code would post live CGEvents into the owner's input).
///
/// Rules every guard follows (plan 009b):
/// - read through `source`/`require`/`keyboardMonitorSources` — never a private `String(contentsOf:)`;
/// - a missing or unreadable file FAILS (a renamed file must not turn a safety check into a pass);
/// - "inside function X" is expressed with `body(ofFunction:in:)` (real brace matching), not with a
///   "from marker A to marker B" pair that silently widens when a neighbour moves;
/// - a known number is asserted EXACTLY, with a message saying what to update when it legitimately changes.
enum SourceContract {
    /// `Sources/QwertySwitcher/` — resolved from this file's own location.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
    }

    /// `relativePath` is relative to `Sources/QwertySwitcher/`; `../../X` reaches the repo root.
    static func url(_ relativePath: String) -> URL {
        sourcesRoot.appendingPathComponent(relativePath).standardized
    }

    /// File text, or nil when unreadable. Callers use `require` unless they report the failure themselves.
    static func source(_ relativePath: String) -> String? {
        try? String(contentsOf: url(relativePath), encoding: .utf8)
    }

    /// Like `source`, but an unreadable file is recorded as a FAILED assertion naming the suite and path.
    static func require(_ relativePath: String, _ suite: String) -> String? {
        if let text = source(relativePath) { return text }
        TestRunner.assertTrue(false, "\(suite): \(relativePath) unreadable")
        return nil
    }

    static func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    /// `Core/KeyboardMonitor.swift`, then `+DoubleShift`, then `+KeyRouting`, joined by `\n`.
    /// nil when ANY of the three is unreadable — the caller must FAIL, never skip.
    static func keyboardMonitorSources() -> String? {
        var parts: [String] = []
        for name in ["KeyboardMonitor.swift", "KeyboardMonitor+DoubleShift.swift", "KeyboardMonitor+KeyRouting.swift"] {
            guard let text = source("Core/" + name) else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    /// `keyboardMonitorSources()` with the failure recorded (suite name in the message).
    static func requireKeyboardMonitorSources(_ suite: String) -> String? {
        if let text = keyboardMonitorSources() { return text }
        TestRunner.assertTrue(false, "\(suite): KeyboardMonitor sources must be readable (all three files)")
        return nil
    }

    /// Exact number of non-overlapping occurrences of `needle`.
    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    // MARK: - Brace-matched scoping

    /// The function whose declaration line contains `signaturePrefix`: its text from the first `{`
    /// after that line starts to the matching `}` (both included). Braces inside string literals
    /// (`"…"`, `#"…"#`, `"""…"""`, interpolations) and comments (`//`, nested `/* */`) are ignored.
    /// nil unless EXACTLY ONE non-comment line contains the prefix and its braces balance — an
    /// ambiguous or vanished target is a failure for the caller, never a silent widening.
    static func body(ofFunction signaturePrefix: String, in text: String) -> String? {
        block(startingAt: signaturePrefix, in: text)
    }

    /// Same matching for any brace-delimited construct (a loop, an `if` branch, a closure) whose
    /// opening line contains `header`. Same exactly-one-line rule.
    static func block(startingAt header: String, in text: String) -> String? {
        guard !header.isEmpty else { return nil }
        let scalars = Array(text.unicodeScalars)
        // Start offsets of the lines holding the header; comment-only lines are excluded.
        var matches: [Int] = []
        var lineStart = 0
        var i = 0
        while i <= scalars.count {
            if i == scalars.count || scalars[i] == "\n" {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[lineStart..<i])
                let line = String(view)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.contains(header), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") {
                    matches.append(lineStart)
                }
                lineStart = i + 1
            }
            i += 1
        }
        guard matches.count == 1 else { return nil }
        let scanner = BraceScanner(scalars)
        guard let open = scanner.firstCodeBrace(from: matches[0]),
              let end = scanner.skipBalanced(from: open + 1, open: "{", close: "}") else { return nil }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[open..<end])
        return String(result)
    }
}

/// Lexer-aware brace matching over Unicode scalars (Swift syntax: raw strings, multi-line strings,
/// interpolation, nested block comments).
private struct BraceScanner {
    let scalars: [Unicode.Scalar]
    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    private func at(_ i: Int) -> Unicode.Scalar? { i < scalars.count ? scalars[i] : nil }

    /// Index of the first `{` at or after `start` that is real code (not in a string or comment).
    func firstCodeBrace(from start: Int) -> Int? {
        var i = start
        while i < scalars.count {
            if let next = skipNonCode(i) { i = next; continue }
            if scalars[i] == "{" { return i }
            i += 1
        }
        return nil
    }

    /// `start` is just AFTER an opening delimiter (depth 1). Returns the index just after its matching
    /// closer, or nil when unbalanced. Only `open`/`close` are counted; strings/comments are skipped.
    func skipBalanced(from start: Int, open: Unicode.Scalar, close: Unicode.Scalar) -> Int? {
        var depth = 1
        var i = start
        while i < scalars.count {
            if let next = skipNonCode(i) { i = next; continue }
            let c = scalars[i]
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return nil
    }

    /// If a comment or string literal starts at `i`, the index just after it; else nil.
    /// An unterminated construct swallows the rest of the text (the caller then sees "unbalanced").
    private func skipNonCode(_ i: Int) -> Int? {
        let c = scalars[i]
        if c == "/", at(i + 1) == "/" {
            var j = i + 2
            while j < scalars.count, scalars[j] != "\n" { j += 1 }
            return j
        }
        if c == "/", at(i + 1) == "*" {
            var depth = 1
            var j = i + 2
            while j < scalars.count {
                if scalars[j] == "/", at(j + 1) == "*" {
                    depth += 1; j += 2
                } else if scalars[j] == "*", at(j + 1) == "/" {
                    depth -= 1; j += 2
                    if depth == 0 { return j }
                } else {
                    j += 1
                }
            }
            return scalars.count
        }
        if c == "\"" || c == "#" { return skipString(i) }
        return nil
    }

    /// A string literal starting at `i` (`#`*n then `"` or `"""`), else nil. Returns the index after it.
    private func skipString(_ i: Int) -> Int? {
        var hashes = 0
        var j = i
        while at(j) == "#" { hashes += 1; j += 1 }
        guard at(j) == "\"" else { return nil }
        let multiline = at(j + 1) == "\"" && at(j + 2) == "\""
        j += multiline ? 3 : 1
        while j < scalars.count {
            let c = scalars[j]
            if c == "\\" {
                // An escape needs the same number of `#`s as the opener (`\#(` in `#"…"#`).
                var k = j + 1
                var seen = 0
                while seen < hashes, at(k) == "#" { seen += 1; k += 1 }
                if seen == hashes {
                    if at(k) == "(" {
                        // Interpolation: real code up to the matching `)` — it may hold strings and braces.
                        guard let after = skipBalanced(from: k + 1, open: "(", close: ")") else { return scalars.count }
                        j = after
                    } else {
                        j = k + 1
                    }
                } else {
                    j += 1
                }
                continue
            }
            if c == "\"" {
                let closes = multiline ? (at(j + 1) == "\"" && at(j + 2) == "\"") : true
                if closes {
                    var k = j + (multiline ? 3 : 1)
                    var seen = 0
                    while seen < hashes, at(k) == "#" { seen += 1; k += 1 }
                    if seen == hashes { return k }
                }
            } else if c == "\n", !multiline {
                return j   // an unterminated single-line string ends at the line break
            }
            j += 1
        }
        return scalars.count
    }
}

/// Fixture tests for the brace matcher and the helper's failure modes.
enum SourceContractHelperTests {
    static func run() {
        TestRunner.section("SourceContract — brace-matched scoping ignores strings and comments")

        func body(_ prefix: String, _ text: String) -> String? { SourceContract.body(ofFunction: prefix, in: text) }

        // Nested closures: the matching brace is the function's, not a closure's.
        let nested = """
        func outer() {
            items.map { x in
                if x > 0 { return 1 } else { return 2 }
            }
            let after = 1
        }
        func other() { let outside = 1 }
        """
        let nestedBody = body("func outer()", nested)
        TestRunner.assertTrue(nestedBody?.hasSuffix("let after = 1\n}") == true, "nested closures: body ends at the function's own closing brace")
        TestRunner.assertTrue(nestedBody?.contains("outside") == false, "nested closures: the next function is not part of the body")

        // A "}" inside a string literal does not close the function.
        let stringBrace = "func f() {\n    let s = \"}\"\n    let marker = 1\n}\nfunc g() { let tail = 1 }"
        let stringBody = body("func f()", stringBrace)
        TestRunner.assertTrue(stringBody?.contains("marker") == true && stringBody?.contains("tail") == false, "a \"}\" string literal does not end the body")

        // A "// }" comment and a block comment do not close it either; nested block comments balance.
        let comments = "func f() {\n    // }\n    /* } /* } */ } */\n    let marker = 1\n}\nfunc g() { let tail = 1 }"
        let commentBody = body("func f()", comments)
        TestRunner.assertTrue(commentBody?.contains("marker") == true && commentBody?.contains("tail") == false, "`// }` and nested `/* } */` comments are ignored")

        // A multi-line string with braces inside.
        let multi = "func f() {\n    let s = \"\"\"\n    } {{ }\n    \"\"\"\n    let marker = 1\n}\nfunc g() { let tail = 1 }"
        let multiBody = body("func f()", multi)
        TestRunner.assertTrue(multiBody?.contains("marker") == true && multiBody?.contains("tail") == false, "braces inside a multi-line string literal are ignored")

        // Raw strings: `#"{"#`, and a `##` raw string holding a plain quote and an unmatched brace.
        let raw = "func f() {\n    let a = #\"{\"#\n    let b = ##\"\"}\"##\n    let marker = 1\n}\nfunc g() { let tail = 1 }"
        let rawBody = body("func f()", raw)
        TestRunner.assertTrue(rawBody?.contains("marker") == true && rawBody?.contains("tail") == false, "raw strings `#\"{\"#` and `##\"\"}\"##` are ignored")

        // Interpolation holding a closure and a nested string literal.
        let interp = "func f() {\n    let s = \"a \\(items.map { \"}\" }.joined()) }\"\n    let marker = 1\n}\nfunc g() { let tail = 1 }"
        let interpBody = body("func f()", interp)
        TestRunner.assertTrue(interpBody?.contains("marker") == true && interpBody?.contains("tail") == false, "interpolation with a closure and a nested string literal is skipped correctly")

        // Signature spanning lines: the first `{` after the matched line belongs to the body.
        let multiSig = "private func f(\n    a: Int,\n    b: Int\n) -> Bool {\n    return true\n}\n"
        TestRunner.assertTrue(body("private func f(", multiSig)?.contains("return true") == true, "a signature spanning several lines still finds its body")

        // A doc comment that names the function is not a declaration; two real declarations are ambiguous.
        let doc = "/// see func f() for details\nfunc f() {\n    let marker = 1\n}\n"
        TestRunner.assertTrue(body("func f()", doc)?.contains("marker") == true, "a comment line naming the signature is not matched")
        let twice = "func f() { }\nfunc f() { }\n"
        TestRunner.assertNil(body("func f()", twice), "two declarations containing the prefix are ambiguous → nil (caller fails)")

        // Missing target and unbalanced text both give nil, never a widened scope.
        TestRunner.assertNil(body("func missing()", nested), "a missing function → nil")
        TestRunner.assertNil(body("func f()", "func f() {\n    let a = 1\n"), "unbalanced braces → nil")

        // `block` scopes an `if`/loop inside a function, including an `} else if` header line.
        let branches = "func f() {\n    if a < b {\n        less()\n    } else if a > b {\n        more()\n    }\n}\n"
        let less = SourceContract.block(startingAt: "if a < b {", in: branches)
        let more = SourceContract.block(startingAt: "} else if a > b {", in: branches)
        TestRunner.assertTrue(less?.contains("less()") == true && less?.contains("more()") == false, "block(): the `if` branch ends at its own closing brace")
        TestRunner.assertTrue(more?.contains("more()") == true && more?.contains("less()") == false, "block(): an `} else if` header scopes the else-if branch only")

        // File access helpers.
        TestRunner.assertNil(SourceContract.source("Core/NoSuchFile.swift"), "an unreadable path gives nil")
        TestRunner.assertEqual(SourceContract.occurrences(of: "ab", in: "ababab-ab"), 4, "occurrences counts exactly")
        TestRunner.assertTrue(SourceContract.keyboardMonitorSources() != nil, "the three KeyboardMonitor files are readable")
    }
}
#endif
