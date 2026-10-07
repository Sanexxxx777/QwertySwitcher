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
    /// The layouts (source, target) of an instant correction that succeeded, kept so the word's
    /// boundary can arm `AutoLearnTracker` with the WHOLE word (the instant path only knows the
    /// prefix typed so far). Same lifetime as `landedLang`.
    private(set) var learnLayouts: (source: String, target: String)?

    /// Call when a letter starts a brand-new word (buffer was empty before it).
    mutating func startNewWord() {
        wasCorrected = false
        landedLang = nil
        learnLayouts = nil
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

    /// Call at the same moment as `markLanded`: remember the layouts for the boundary's auto-learn.
    mutating func markLearnable(sourceLayoutID: String, targetLayoutID: String) {
        learnLayouts = (sourceLayoutID, targetLayoutID)
    }

    /// Call from the word-boundary handler. Returns true (and clears the
    /// gate) exactly once per instantly-corrected word, so the boundary path
    /// knows to skip its own correction attempt.
    mutating func consumeIfCorrected() -> Bool {
        guard wasCorrected else { return false }
        wasCorrected = false
        landedLang = nil
        learnLayouts = nil
        return true
    }

    /// Call on any context invalidation (click, focus change, modifiers).
    mutating func reset() {
        wasCorrected = false
        landedLang = nil
        learnLayouts = nil
    }
}
