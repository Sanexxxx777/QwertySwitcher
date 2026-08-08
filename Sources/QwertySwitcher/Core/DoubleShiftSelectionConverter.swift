import Foundation
import ApplicationServices
import CoreGraphics

/// Converts text that was typed in the WRONG keyboard layout but is only
/// available to us as an already-rendered string (AX-selected text, clipboard
/// contents, or the word before the caret) — as opposed to
/// `InputSourceManager.convertKeystrokes`, which needs the original physical
/// keycodes. Reverse-maps every character back to the physical key that
/// produced it in `sourceLayout`, then re-translates that key through
/// `targetLayout`. Characters with no reverse mapping (digits, emoji,
/// punctuation outside the letter row) pass through unchanged.
enum LayoutTextConverter {
    /// EVERY physical key that prints something — letters, digits and the
    /// symbol keys between them. Restricting this to letters meant a symbol
    /// whose meaning genuinely differs between layouts could never convert:
    /// keycode 44 is "/" in QWERTY and "." in ЙЦУКЕН, so "/exit" typed on
    /// Russian showed ".учше" and came back as ".exit" — the letters moved
    /// alphabet and the symbol was silently left behind. Same for Shift-digits
    /// ("№" vs "#"). Keys that print the same character in both layouts (plain
    /// digits) map to themselves and pass through unchanged, which costs
    /// nothing.
    private static let printableKeycodes: [UInt16] = (UInt16(0)...UInt16(50))
        .filter { InputBuffer.isLetterKey($0) || InputBuffer.isNumberOrSpecial($0) }
    /// Letters only. `keystrokes(for:)` deliberately keeps this narrower set:
    /// returning nil on mixed content is how the SCORED path learns it is not
    /// applicable, and a run with digits in it is not a dictionary word.
    private static let letterKeycodes: [UInt16] = (UInt16(0)...UInt16(50)).filter(InputBuffer.isLetterKey)

    private static func reverseMap(
        for layout: KeyboardLayout, inputSourceManager: InputSourceManager,
        keycodes: [UInt16]
    ) -> [Character: (keycode: UInt16, flags: CGEventFlags)] {
        var map: [Character: (keycode: UInt16, flags: CGEventFlags)] = [:]
        for code in keycodes {
            for flags: CGEventFlags in [[], .maskShift] {
                guard let s = inputSourceManager.characterForKeycode(code, layout: layout, flags: flags),
                      let ch = s.first, s.count == 1 else { continue }
                // First writer wins. Two keys can print the same character on
                // one layout (Russian has "." on both 44 and Shift-47); letting
                // a later one overwrite would make the mapping depend on
                // iteration order rather than on anything meaningful.
                if map[ch] == nil { map[ch] = (code, flags) }
            }
        }
        return map
    }

    /// Reconstructs the physical keystrokes that would have produced `text`
    /// on `layout`. Returns nil if any character has no reverse mapping
    /// (mixed content, punctuation) — callers use this to decide whether the
    /// scored `LanguageDetector.detect` path is even applicable.
    static func keystrokes(
        for text: String, typedOn layout: KeyboardLayout, inputSourceManager: InputSourceManager
    ) -> [BufferedKeystroke]? {
        guard !text.isEmpty else { return nil }
        let reverse = reverseMap(
            for: layout, inputSourceManager: inputSourceManager, keycodes: letterKeycodes
        )
        var result: [BufferedKeystroke] = []
        result.reserveCapacity(text.count)
        for ch in text {
            guard let m = reverse[ch] else { return nil }
            result.append(BufferedKeystroke(keycode: m.keycode, flags: m.flags))
        }
        return result
    }

    /// Direct char-by-char re-translation, case preserved. Characters with no
    /// reverse mapping on `sourceLayout` are copied through unchanged.
    static func convert(
        _ text: String, from sourceLayout: KeyboardLayout, to targetLayout: KeyboardLayout,
        inputSourceManager: InputSourceManager
    ) -> String {
        guard !text.isEmpty else { return text }
        let reverse = reverseMap(
            for: sourceLayout, inputSourceManager: inputSourceManager, keycodes: printableKeycodes
        )
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            if let m = reverse[ch],
               let converted = inputSourceManager.characterForKeycode(m.keycode, layout: targetLayout, flags: m.flags) {
                result += converted
            } else {
                result.append(ch)
            }
        }
        return result
    }
}

/// Pure text-slicing helper for the "word immediately before the caret"
/// Double Shift path — no selection exists, only a caret position inside the
/// full field value. Kept free of AX types so it is unit-testable without a
/// live focused element.
enum CaretWordExtractor {
    struct Result: Equatable {
        let word: String
        /// UTF-16 range within the ORIGINAL string — AX addresses text
        /// ranges in UTF-16 offsets, not `String.Index`.
        let utf16Range: NSRange
    }

    /// - Parameters:
    ///   - text: full field value.
    ///   - caretUTF16Offset: caret position (UTF-16 code units from the start).
    /// Returns nil when the caret sits at the very start, right after
    /// whitespace, or the word is shorter than 2 characters (mirrors the
    /// `count >= 2` floor the buffer/history path already uses).
    static func wordBeforeCaret(text: String, caretUTF16Offset: Int) -> Result? {
        let full = text as NSString
        let caret = max(0, min(caretUTF16Offset, full.length))
        guard caret > 0 else { return nil }

        let lastChar = full.substring(with: NSRange(location: caret - 1, length: 1))
        guard lastChar.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        var start = caret
        while start > 0 {
            let ch = full.substring(with: NSRange(location: start - 1, length: 1))
            if ch.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            start -= 1
        }
        let range = NSRange(location: start, length: caret - start)
        // Single-character words count — same reason as the buffer path in
        // KeyboardMonitor.swapLastWordInBuffer (и, а, в, к, с, я, о, у).
        guard range.length >= 1 else { return nil }
        return Result(word: full.substring(with: range), utf16Range: range)
    }
}

/// Reads/writes the system-wide focused UI element's text selection — used by
/// Double Shift's selection and caret-word conversion paths. All calls are
/// best-effort: any failure returns nil/false and the caller falls through to
/// the next path — never throws, never retries, never sends synthetic
/// caret-moving keystrokes (that is what broke Double Shift in the v0.2.0
/// hotfix; see CLAUDE.md — the ban still stands).
enum AXTextSelectionService {
    /// Every AX call below is a synchronous round-trip to another process. The
    /// AX default timeout is 6 seconds, and an unresponsive app spends all of
    /// it: measured 2552ms on one Double Shift in Ghostty (log 07:11:51→53)
    /// against 213ms for the same path when the app answered. That stall runs
    /// on the main thread, i.e. the app goes blind while the user keeps typing
    /// — the buffer then no longer matches the screen, which is what produced
    /// the leftover characters in "./compact". A tight bound turns a freeze
    /// into a clean miss, and a miss just falls through to the next path.
    private static let axTimeoutSeconds: Float = 0.15

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, axTimeoutSeconds)
        var focusedAppRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef
        ) == .success else { return nil }
        let appElement = unsafeBitCast(focusedAppRef, to: AXUIElement.self)
        _ = AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)

        // Chromium/Electron apps (Telegram, Slack, Discord, VSCode) never
        // build an accessibility tree for their web content unless nudged —
        // normally that only happens once VoiceOver (or another assistive
        // tech) has run. Setting this informal-but-widely-relied-upon
        // attribute (the same one VoiceOver sets) wakes it up; best-effort,
        // harmless no-op on apps/windows that don't recognize it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success else { return nil }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    /// Non-empty selected text, or nil if there is none / the app's AX tree
    /// doesn't expose it (common in Electron apps and some terminals).
    static func selectedText(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    /// Full field value + caret position, for the "word before caret" path.
    /// Returns nil unless there is a ZERO-length selection (a plain caret,
    /// i.e. nothing selected) — an actual selection is handled by
    /// `selectedText` instead, one priority level above this.
    static func valueAndCaret(_ element: AXUIElement) -> (text: String, caret: Int)? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String else { return nil }

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success else { return nil }
        let axRange = unsafeBitCast(rangeRef, to: AXValue.self)
        var cfRange = CFRange()
        guard AXValueGetType(axRange) == .cfRange,
              AXValueGetValue(axRange, .cfRange, &cfRange) else { return nil }
        guard cfRange.length == 0 else { return nil }
        return (text, cfRange.location)
    }

    @discardableResult
    static func replaceRange(_ range: NSRange, with text: String, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axRange
        ) == .success else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }
}
