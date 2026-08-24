import Foundation

/// Mechanism B state-machine: classifies Double Shift gestures against
/// recent automatic-correction / manual-conversion history to tell a
/// genuine manual fix apart from an undo (revert) or a toggle-back. All
/// state is in-memory only, no persistence, no `Date()` inside — every
/// entry point takes `at: Date`.
///
/// Comparisons between words are case-insensitive throughout.
final class CorrectionFeedbackTracker {
    /// Classification of a Double Shift gesture, given recent automatic
    /// corrections and recent manual (Double Shift) conversions.
    enum Verdict: Equatable {
        /// This DS undoes a recent automatic correction — caller should
        /// `learnException(original:corrected:)` + `unlearn` in both
        /// stores, then still perform the DS conversion normally.
        case revertOfAutoCorrection(original: String, corrected: String, wasLearned: Bool)
        /// This DS undoes the previous manual DS on the same word —
        /// caller should `revokeRecord(word:lang:)` on
        /// `LearnedWordsStore` (mechanism A's anti-toggle).
        case toggleOfManualFix(word: String, lang: String)
        /// Neither of the above — a genuine manual fix, caller should
        /// `recordManualFix` (mechanism A).
        case manualFix
    }

    private struct AutoCorrectionRecord {
        let original: String
        let corrected: String
        let targetLang: String
        let wasLearned: Bool
        let at: Date
    }

    private struct ManualConversionRecord {
        let word: String
        let sourceLang: String
        let targetLang: String
        let at: Date
        var consumed: Bool
    }

    private struct RevertRecord {
        let original: String
        let corrected: String
        let at: Date
    }

    private let revertWindow: TimeInterval = 8
    private let toggleWindow: TimeInterval = 10
    private let revertOfRevertWindow: TimeInterval = 15

    private var pendingAutoCorrection: AutoCorrectionRecord?
    private var pendingManualConversion: ManualConversionRecord?
    private var pendingRevert: RevertRecord?

    init() {}

    // MARK: - Recording

    /// Called from both automatic-correction success paths (instant and
    /// boundary) right after the correction actually landed.
    func recordAutoCorrection(original: String, corrected: String, targetLang: String, wasLearned: Bool, at: Date) {
        pendingAutoCorrection = AutoCorrectionRecord(
            original: original, corrected: corrected, targetLang: targetLang, wasLearned: wasLearned, at: at
        )
    }

    /// Remembers the *result* of a manual Double Shift conversion (the word
    /// as it now reads, and the direction that produced it) for one-shot
    /// toggle detection: `word` is the converted spelling, `sourceLang` is
    /// the language it was converted FROM, `targetLang` is the language it
    /// now reads as.
    func recordManualConversion(word: String, sourceLang: String, targetLang: String, at: Date) {
        pendingManualConversion = ManualConversionRecord(
            word: word, sourceLang: sourceLang, targetLang: targetLang, at: at, consumed: false
        )
    }

    /// Called after a `.revertOfAutoCorrection` verdict was acted upon
    /// (exception learned) — enables `classifyRevertOfRevert` to detect an
    /// immediate change of heart.
    func recordRevert(original: String, corrected: String, at: Date) {
        pendingRevert = RevertRecord(original: original, corrected: corrected, at: at)
    }

    // MARK: - Classification

    /// `word`/`sourceLang`/`targetLang` describe the Double Shift gesture as
    /// it is about to run: `word` is the text as currently typed (in
    /// `sourceLang`), `targetLang` is the language it would convert to.
    func classifyDoubleShift(word: String, sourceLang: String, targetLang: String, at: Date) -> Verdict {
        let lowered = word.lowercased()

        if let pending = pendingAutoCorrection,
           lowered == pending.corrected.lowercased(),
           sourceLang == pending.targetLang,
           at.timeIntervalSince(pending.at) <= revertWindow {
            pendingAutoCorrection = nil
            return .revertOfAutoCorrection(
                original: pending.original, corrected: pending.corrected, wasLearned: pending.wasLearned
            )
        }

        if let pending = pendingManualConversion,
           !pending.consumed,
           lowered == pending.word.lowercased(),
           sourceLang == pending.targetLang,
           targetLang == pending.sourceLang,
           at.timeIntervalSince(pending.at) <= toggleWindow {
            pendingManualConversion?.consumed = true
            return .toggleOfManualFix(word: pending.word, lang: pending.targetLang)
        }

        return .manualFix
    }

    /// Detects a Double Shift heading back in the direction of a correction
    /// that was just annulled by a revert (≤15s) — signals the caller to
    /// lift the auto-learned exception it just created, since one accidental
    /// gesture should not permanently disable correction for the word.
    ///
    /// `word` is compared against the reverted `original` (that is what a
    /// revert restores on screen); `targetLang` is accepted for signature
    /// symmetry with `classifyDoubleShift` but not gated on separately —
    /// this store never learns a language for `corrected` (see
    /// `recordRevert`), and in this product's binary layout model a fresh
    /// DS on the just-reverted word structurally has nowhere else to go.
    /// One-shot: a match consumes the pending revert.
    func classifyRevertOfRevert(word: String, targetLang: String, at: Date) -> Bool {
        guard let pending = pendingRevert,
              word.lowercased() == pending.original.lowercased(),
              at.timeIntervalSince(pending.at) <= revertOfRevertWindow else {
            return false
        }
        pendingRevert = nil
        return true
    }

    // MARK: - Reset

    /// Called from all 8 context-invalidation points (wave 2): editing
    /// context reset, external layout change, secure input, navigation
    /// keys, backspace, stale timeout, `undoLastCorrection`. Clears every
    /// piece of in-flight state.
    func reset() {
        pendingAutoCorrection = nil
        pendingManualConversion = nil
        pendingRevert = nil
    }
}
