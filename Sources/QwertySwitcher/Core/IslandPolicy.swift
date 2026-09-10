import Foundation

/// Pure decision for the "island" feature (v0.11.0, field data 08-10.09.2026
/// — owner's 1.5-day verbose log: of 71 ru→en layout drifts, the next word
/// was Russian and had to be fixed by hand or auto-correction in 49 cases;
/// a single foreign word should not leave the layout stuck in that language).
///
/// Has zero dependency on `KeyboardMonitor`/`LanguageDetector` internals on
/// purpose — see `LanguageDetectorRingTests` and `IslandPolicyTests` in
/// `IslandTests.swift`, which exercise this against a table of ring shapes
/// with no CGEventTap/AX/TIS involved at all.
enum IslandPolicy {
    /// Returns the language the layout should be restored TO, or `nil` if it
    /// should stay exactly where the just-fired correction left it.
    ///
    /// - Parameter context: the (at most 2) `ContextSlot`s immediately
    ///   BEFORE the word that was just corrected — NOT including that word
    ///   itself. Splitting "exclude the current word" out to the caller
    ///   (`KeyboardMonitor.restoreIsland`) rather than doing it here keeps
    ///   this function ignorant of the ring's max-3 capacity and of whether
    ///   the current word happened to reach the ring at all (it doesn't, for
    ///   instant corrections — see `restoreIsland`'s doc comment).
    /// - Parameter target: the language the just-corrected word landed in.
    /// - Parameter isTerminal: `ax=none` terminals (CLAUDE.md) can't resync
    ///   an unsolicited layout swap against the screen — never restore there.
    static func shouldRestore(
        context: [LanguageDetector.ContextSlot], target: String, isTerminal: Bool
    ) -> String? {
        guard !isTerminal else { return nil }
        // "At least 2 slots" — take the freshest 2 regardless of whether the
        // ring holds exactly 2 or the full 3 (see `restoreIsland`'s
        // `pendingIslandRingIncludesTarget == false` case, where the ring
        // was never touched by the current word and may still hold 3).
        guard context.count >= 2 else { return nil }
        let previous = context.suffix(2)
        guard let older = previous.first, let newer = previous.last else { return nil }

        // Both of the two words before the island must read as a CLEAN run
        // in the same language — clean meaning they landed there without a
        // correction firing. A corrected slot in that pair means the owner
        // was already mid-correction/mid-toggle right before this word, not
        // settled in one language, so restoring here is a guess, not a fact.
        guard older.lang == newer.lang, !older.corrected, !newer.corrected else { return nil }

        let contextLanguage = older.lang
        // Restoring TO the language the word was just corrected INTO is a
        // no-op by definition — there's nothing to snap back to.
        guard contextLanguage != target else { return nil }
        return contextLanguage
    }
}
