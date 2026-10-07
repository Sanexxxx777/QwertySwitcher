import Foundation

/// Tracks whether the word currently being typed has already been fixed by
/// the instant (mid-word) correction path, so the word-boundary handler
/// (space/punctuation) does not correct the same word a second time.
/// A brand-new word (buffer empty right before the next letter) always
/// resets the gate.
struct InstantCorrectionGate {
    private(set) var wasCorrected = false
    /// The language the instant correction landed the word in, set at its SUCCESS. The island
    /// ring slot for the word is written from this at its boundary (one slot per word, written
    /// when the word lands) — not mid-word, where a Backspace or a Double Shift could still
    /// change the outcome. Cleared with `wasCorrected` everywhere.
    private(set) var landedLang: String?

    /// Call when a letter starts a brand-new word (buffer was empty before it).
    mutating func startNewWord() {
        wasCorrected = false
        landedLang = nil
    }

    /// Call when instant correction fires for the word currently in the buffer.
    mutating func markCorrected() {
        wasCorrected = true
    }

    /// Call when the instant correction SUCCEEDED (after `markCorrected()`): records where the
    /// word landed, for the boundary's ring slot.
    mutating func markLanded(lang: String) {
        landedLang = lang
    }

    /// Call from the word-boundary handler. Returns true (and clears the
    /// gate) exactly once per instantly-corrected word, so the boundary path
    /// knows to skip its own correction attempt.
    mutating func consumeIfCorrected() -> Bool {
        guard wasCorrected else { return false }
        wasCorrected = false
        landedLang = nil
        return true
    }

    /// Call on any context invalidation (click, focus change, modifiers).
    mutating func reset() {
        wasCorrected = false
        landedLang = nil
    }
}
