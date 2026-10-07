import Foundation
import CoreGraphics
import AppKit
import Darwin

extension KeyboardMonitor {
    /// Double Shift on a run the dictionary cannot judge: convert it key for
    /// key, no scoring at all. Two live cases this exists for:
    ///
    /// - `7ю6с` (meant `7.6s`) — the digits slice it into three fragments none
    ///   of which is a word, so the scoring path had nothing to offer and the
    ///   gesture did nothing at all (log 09:07:51–09:08:08, three presses, all
    ///   "no selection/buffer/history/caret word").
    /// - `пgmail` — the scoring buffer held 5 keystrokes while 6 characters
    ///   were on screen, so the conversion erased five and left the stray
    ///   first one behind (log 09:11:30, `len=5 bs=5 pay=5`). `runKeystrokes`
    ///   is filled before any of the branches that slice `buffer`, so it does
    ///   not drift the same way.
    ///
    /// Deliberately limited to runs containing a non-letter: for a pure word
    /// the scored path picks the target layout intelligently, and that
    /// calibration is left exactly as it was.
    private func convertWholeRun() -> Bool {
        // Cleared on every call, not just the branch that fills it — every
        // exit path below is a fresh reset first, an explicit fill only in
        // the one branch that produced a real screen measurement, so a stale
        // value from an earlier word can never leak into this one.
        pendingRunResync = nil
        pendingRunResyncWord = nil
        guard let currentLayout = languageDetector.inputSourceManager.currentLayout,
              let targetLayout = languageDetector.activeLayouts.first(where: { $0.id != currentLayout.id })
        else { return false }

        // The screen wins over the model whenever we can read it. Our own
        // record of what was typed drifts — it did in "пgmail" (5 keystrokes
        // tracked, 6 characters on screen) and again in "йq1", where the run
        // was one keystroke short and the conversion left the first character
        // stranded. Every such bug erases the wrong number of characters, so
        // measuring the real text is worth an AX round trip on a gesture the
        // user made deliberately. When AX says nothing (many terminals and
        // Electron fields), the tracked run is still the best we have.
        // Nothing typed since the last break: there is no run to convert, and
        // the history path below handles that case. Checked before the AX call
        // so an ordinary word conversion never pays for a cross-process round
        // trip it cannot use.
        let run = runKeystrokes
        guard !run.isEmpty else {
            // Silence here was itself a diagnosis gap: with no line at all,
            // "the run was empty" looked exactly like "this code never ran"
            // (owner's «ы1», 20:01:50 — three seconds after a correction, and
            // nothing in the log said which of the two it was).
            DebugLog.shared.log("KM", "run check: empty run — nothing typed since the last break")
            return false
        }
        let modelText = languageDetector.inputSourceManager.convertKeystrokes(run, toLayout: currentLayout)
        var onScreen = modelText
        var resynced = false
        // Logged on EVERY outcome, not just the resync. A silent "no line in
        // the log" was indistinguishable between "AX agreed", "AX returned
        // nothing" and "we never asked" — which cost a whole diagnosis round
        // on the "./exit" report (18:43:06: conversion counted 5 characters,
        // six had been typed, and nothing said whether the screen was ever
        // consulted).
        let axWord = focusedTextProvider()
            .flatMap { CaretWordExtractor.wordBeforeCaret(text: $0.text, caretUTF16Offset: $0.caret) }
            .map(\.word)
        if let actual = axWord, actual != modelText {
            onScreen = actual
            resynced = true
        }
        DebugLog.shared.log(
            "KM",
            "run check: model=\(modelText.count) ax=\(axWord.map { String($0.count) } ?? "none")"
                + " → \(resynced ? "resynced to screen" : "model kept")"
        )

        // >= 1, matching the buffer path below: Double Shift is an explicit
        // gesture, not a judgement call, and a lone symbol is exactly the kind
        // of thing it exists for ("ю" typed where "." was meant). The guard
        // right after this one still requires a non-letter in the run, so a
        // single LETTER keeps going to the scored path as before.
        guard onScreen.count >= 1 else {
            DebugLog.shared.log("KM", "run check: empty — falls through to the scored path")
            return false
        }
        guard onScreen.contains(where: { !$0.isLetter }) else {
            // The AX measurement above is real regardless of which branch
            // uses it — stash it for the scored path about to run
            // (`swapLastWordInBuffer`, right after this call returns).
            if resynced {
                pendingRunResync = onScreen.count
                pendingRunResyncWord = onScreen
            }
            DebugLog.shared.log("KM", "run check: letters only — falls through to the scored path")
            return false
        }

        // Keycodes are the precise source: they render every key correctly,
        // including the ones outside the letter row ("/" in "/exit", which has
        // no reverse mapping and would otherwise pass through as the "." it
        // currently shows). The text converter is the fallback for exactly one
        // situation — the model disagreed with the screen, so its keycodes
        // describe something other than what is actually there.
        let converted = resynced
            ? LayoutTextConverter.convert(
                onScreen, from: currentLayout, to: targetLayout,
                inputSourceManager: languageDetector.inputSourceManager
              )
            : languageDetector.inputSourceManager.convertKeystrokes(run, toLayout: targetLayout)
        guard !converted.isEmpty, converted != onScreen else { return false }

        isPaused = true
        textReplacer.replaceCurrentWord(
            length: onScreen.count,
            replacement: converted,
            targetLayout: targetLayout,
            trailing: nil,
            trailingAlreadyOnScreen: true
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.switchUndoManager.record(
                    originalKeycodes: run.map(\.keycode),
                    originalWord: onScreen,
                    correctedWord: converted,
                    trailing: nil,
                    originalLayoutID: currentLayout.id,
                    targetLayoutID: targetLayout.id
                )
                self.buffer.clear()
                // The gesture already decided where the word landed (via run: deliberately no
                // slot, plan 004b A4) — the word's boundary must not add a stale instant landing.
                self.instantCorrectionGate.reset()
                self.pendingLeadingSymbols.removeAll()
                self.lastCompletedWord = nil
                // Mechanism A/B (learning_spec.md): "via run" IS one of the
                // three A-eligible sources. Deliberately limited to runs
                // containing a non-letter (this function's own contract) —
                // `normalizedLearnableCore` rejects most of them via its own
                // ">1 core / empty" guard, which is correct: a mixed run is
                // a gesture, not a confirmed word pair.
                let learnableCore = self.normalizedLearnableCore(
                    from: converted, lang: targetLayout.languageCode,
                    own: onScreen, ownLang: currentLayout.languageCode, resynced: resynced
                )
                let positiveRecord = learnableCore.map { (core: $0, originApp: self.activeAppBundleID) }
                self.handleDoubleShiftClassification(
                    word: onScreen, sourceLang: currentLayout.languageCode, targetLang: targetLayout.languageCode,
                    positiveRecord: positiveRecord, at: Date()
                )
                self.statsService.recordOptionSwitch()
                SoundService.shared.playSwitch(
                    targetLanguageCode: targetLayout.languageCode, prefsService: self.prefsService
                )
                NotificationCenter.default.post(name: .statsUpdated, object: nil)
                // The run's last keystroke may be the trigger the sentence
                // tracker already judged at its boundary: "dot?" typed in EN
                // becomes "вще," (plan 012, 23.09.2026). Re-judge only when
                // that last symbol ends a sentence on either side; a run that
                // ends in a letter leaves the tracker alone — it may hold the
                // armed capital for the word still being typed.
                if let before = onScreen.last, let after = converted.last,
                   ".!?".contains(before) || ".!?".contains(after) {
                    self.sentenceStartTracker.reobserveTrailing(String(after))
                }
                DebugLog.shared.log(
                    "KM",
                    "doubleShift via run: \(currentLayout.languageCode)→\(targetLayout.languageCode)"
                        + " len=\(onScreen.count) net=\(converted.count - onScreen.count)"
                )
            case .layoutSwitchFailed:
                DebugLog.shared.log("KM", "doubleShift run aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "doubleShift run cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    /// Try to swap the last word currently sitting in the input buffer.
    /// Returns true if a correction was applied. Called from Double Shift hotkey.
    @discardableResult
    func swapLastWordInBuffer() -> Bool {
        guard !isPaused else { return false }
        if convertWholeRun() { return true }
        var keystrokes = buffer.currentWord()
        var trailing: String? = nil
        var trailingKeystroke: BufferedKeystroke? = nil
        // Layout-dependent symbol(s) typed right before this word (e.g. "/"
        // in "/exit", "$" in "$GRAF") — tracked separately from `keystrokes`
        // exactly like the boundary/instant-correction paths, and folded
        // into the SAME transaction below instead of being silently left
        // un-converted (the ".yexit" bug, pinned by the "/exit" cases of KeyboardMonitorIntegrationTests: this path used to ignore
        // `pendingLeadingSymbols` entirely).
        var leadingSymbols = pendingLeadingSymbols
        var source = "buffer"
        // The word must be scored against the layout it was ACTUALLY typed
        // on, never "whatever is active right now": for a word still live in
        // `buffer` that IS the layout active right now (no drift possible —
        // any layout change clears the buffer), but for a word pulled from
        // `lastCompletedWord` history (no TTL) the active layout can easily
        // have drifted since typing — see MarzheDoubleShiftRegressionTests.
        var typedLayout = languageDetector.inputSourceManager.currentLayout

        // Fallback: buffer was cleared by a trailing space/punct — use the
        // history slot we captured at the word boundary. No TTL: as long as
        // the word hasn't been replaced by a new one, Double Shift must work.
        // History is invalidated only when a new word starts or after a
        // successful conversion (line below this function).
        // Only an EMPTY buffer falls back to history. A single live keystroke
        // is a word the user is looking at right now ("b" → "и"), and it must
        // win over an older history slot — owner hit exactly this: five Double
        // Shifts on a lone "b" did nothing (log 07:49:54-57, all five
        // "no selection/buffer/history/caret word").
        // The history slot carries the SAME floor as the live buffer (>= 1):
        // a one-letter word is ordinary Russian (и, а, в, к, с, я, о, у), and
        // pressing space before reaching for Double Shift must not be what
        // decides whether the gesture works. The floor here used to be 2, so
        // "b" + space + Double Shift did nothing while "b" + Double Shift
        // converted — the same inconsistency the 05.08 lone-"b" report was
        // about, one keystroke later.
        if keystrokes.isEmpty {
            if let last = lastCompletedWord, last.keystrokes.count >= 1 {
                keystrokes = last.keystrokes
                trailing = last.trailing
                typedLayout = last.typedLayout
                leadingSymbols = last.leadingSymbols
                trailingKeystroke = last.trailingKeystroke
                source = "history"
            }
        }

        // >= 1, not >= 2: single-letter words are ordinary Russian (и, а, в, к,
        // с, я, о, у). This threshold is lifted for the EXPLICIT Double Shift
        // gesture only — automatic correction keeps its own, higher bar, where
        // a false positive would rewrite a command-line flag (`rm -f` → `rm -а`).
        guard keystrokes.count >= 1, let currentLayout = typedLayout else { return false }
        // `swapTarget` NEVER sees `leadingSymbols` — only the letter core is
        // scored, exactly as before this fix, so the calibrated decision is
        // unaffected by a symbol sitting in front of the word.
        guard let swap = languageDetector.swapTarget(keystrokes: keystrokes, typedLayout: currentLayout) else {
            return false
        }
        let targetLayout = swap.layout
        let correctedWord = swap.word

        // Same layout-dependent trigger re-render as the boundary path
        // (`processCurrentWord`): the trailing symbol pulled from history was
        // rendered on the layout it was TYPED on, not the one Double Shift is
        // about to switch INTO.
        if let trailingKeystroke {
            trailing = languageDetector.inputSourceManager.characterForKeycode(
                trailingKeystroke.keycode, layout: targetLayout, flags: trailingKeystroke.flags
            ) ?? trailing
        }

        let originalWordOnly = languageDetector.lastConvertedWord(keystrokes: keystrokes) ?? ""
        let leadingOriginalText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: currentLayout)
        let leadingCorrectedText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: targetLayout)
        let runReplacement = leadingCorrectedText + correctedWord
        let originalWord = leadingOriginalText + originalWordOnly

        isPaused = true
        // `convertWholeRun`, called at the top of this function, already
        // measured the real on-screen word when it fell through here
        // (letters only — a dictionary judgement, not its call). Reusing
        // THAT length for the erase, instead of re-deriving it from
        // `keystrokes`, is what actually fixes the drift: the model is what
        // disagreed with the screen in the first place. Only the erase count
        // changes — `swap.word` above was already scored from `keystrokes`
        // and stays exactly that; the screen decides how much to erase, the
        // keycodes decide what to type. `source == "buffer"` is a belt: the
        // measurement only ever comes from the run just typed, never from a
        // `lastCompletedWord` snapshot pulled out of history.
        var length = leadingSymbols.count + keystrokes.count
        // Safe direction — unconditional: erasing LESS than modelled can
        // only leave a stray character behind (self-heals on the next
        // correction), never eat real text.
        if let measured = pendingRunResync,
           KeyboardMonitor.shouldClampToScreen(model: length, measured: measured) {
            DebugLog.shared.log("KM", "run check: erase resynced \(length)→\(measured) (source=\(source))")
            length = measured
        // Dangerous direction — only with proof the extra characters on
        // screen are OUR OWN artifact, not text the user already had.
        } else if let measured = pendingRunResync, let screenWord = pendingRunResyncWord,
                  KeyboardMonitor.shouldExtendToScreen(
                      model: length, measured: measured, modelWord: originalWordOnly, screenWord: screenWord
                  ) {
            DebugLog.shared.log("KM", "run check: erase resynced \(length)→\(measured) (source=\(source))")
            length = measured
        }
        // Captured before the clear below — Mechanism A's "resynced == true
        // → не учить" guard (learning_spec.md): a word this call re-measured
        // from the screen is not necessarily what the owner actually typed.
        let wasResynced = pendingRunResync != nil
        pendingRunResync = nil
        pendingRunResyncWord = nil

        textReplacer.replaceCurrentWord(
            length: length,
            replacement: runReplacement,
            targetLayout: targetLayout,
            trailing: trailing,
            trailingAlreadyOnScreen: true
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.switchUndoManager.record(
                    originalKeycodes: leadingSymbols.map(\.keycode) + keystrokes.map(\.keycode),
                    originalWord: originalWord,
                    correctedWord: runReplacement,
                    trailing: trailing,
                    originalLayoutID: currentLayout.id,
                    targetLayoutID: targetLayout.id
                )
                self.buffer.clear()
                // Same as "via run": a Double Shift owns the word's landing; drop the instant one.
                self.instantCorrectionGate.reset()
                // Only the LIVE pendingLeadingSymbols run was actually
                // consumed above when `source == "buffer"` — the history
                // path reused a snapshot already captured earlier, so it
                // must not clobber a leading symbol the user may have
                // started typing for the NEXT word in the meantime.
                if source == "buffer" {
                    self.pendingLeadingSymbols.removeAll()
                }
                // Re-arm history with the JUST-PRODUCED word (leading symbol
                // included), tagged with the layout it's now displayed in —
                // NOT cleared to nil. A second, immediate Double Shift on the
                // same word finds it here; since the scorer correctly
                // refuses to switch away from a now-good word, `swapTarget`'s
                // forced-fallback branch flips it straight back (toggle),
                // instead of falling through to caret-word/Undo (which used
                // to make it look like the feature needed 2-3 presses to
                // "finally" work).
                self.lastCompletedWord = (keystrokes, trailing ?? "", targetLayout, leadingSymbols, trailingKeystroke)
                // Mechanism A/B (learning_spec.md): "via buffer"/"via
                // history" are the other two A-eligible sources.
                // `correctedWord` (not `runReplacement`) — lead symbols
                // never enter the learned pair.
                let learnableCore = self.normalizedLearnableCore(
                    from: correctedWord, lang: targetLayout.languageCode,
                    own: originalWordOnly, ownLang: currentLayout.languageCode, resynced: wasResynced
                )
                let positiveRecord = learnableCore.map { (core: $0, originApp: self.activeAppBundleID) }
                self.handleDoubleShiftClassification(
                    word: originalWordOnly, sourceLang: currentLayout.languageCode, targetLang: targetLayout.languageCode,
                    positiveRecord: positiveRecord, at: Date()
                )
                self.statsService.recordOptionSwitch()
                SoundService.shared.playSwitch(targetLanguageCode: targetLayout.languageCode, prefsService: self.prefsService)
                NotificationCenter.default.post(name: .statsUpdated, object: nil)
                DebugLog.shared.log(
                    "KM",
                    "doubleShift via \(source): \(currentLayout.languageCode)→\(targetLayout.languageCode)"
                        + " len=\(length) lead=\(leadingSymbols.count) trail=\(trailing ?? "∅")"
                        // Nothing is suppressed on this path — Double Shift is
                        // invoked after the trailing character already landed —
                        // so retyped and erased must simply match.
                        + " net=\(runReplacement.count - length)"
                )
                // This path re-renders `trailing` for the target layout too
                // (see `trailing = …characterForKeycode(… layout: targetLayout
                // …)` above) — the sentence tracker must judge it same as the
                // boundary path does.
                if let trailing, !trailing.isEmpty {
                    self.sentenceStartTracker.reobserveTrailing(trailing)
                }
                // Island: `swapTarget` (called above, before `isPaused` was
                // set) runs `languageDetector.detect` synchronously, so the
                // ring already carries this word's own entry — same as the
                // boundary path. "via buffer": the word's own boundary has
                // already been consumed (that's how it got INTO the buffer/
                // history in the first place), so there is no future
                // boundary to defer to — wait for the NEXT word's instead,
                // same mechanism instant correction uses. "via history": the
                // word is long finished — restore right now.
                //
                // `swapTarget` writes nothing to the ring any more. The context is captured
                // BEFORE this word's slot is written: "buffer" — the word never reached a boundary,
                // no slot yet → the last 2; "history" — its boundary already pushed one → the 2
                // before it. Then the slot is written once: added (buffer) or replaced (history).
                let ring = self.languageDetector.contextSlots
                let isHistory = source != "buffer"
                self.pendingIslandContext = Array((isHistory ? ring.dropLast() : ring[...]).suffix(2))
                self.languageDetector.recordLandedWord(
                    lang: targetLayout.languageCode, corrected: true, replacingLast: isHistory
                )
                self.pendingIslandTarget = targetLayout.languageCode
                if source == "buffer" {
                    self.pendingIslandRestore = true
                } else if !self.hasQueuedKeyDown {
                    self.restoreIsland(path: "ds")
                } else {
                    self.pendingIslandRestore = true
                    DebugLog.shared.log("KM", "island: skipped reason=queueNonEmpty path=ds", level: .verbose)
                }
            case .layoutSwitchFailed:
                DebugLog.shared.log("KM", "doubleShift aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "doubleShift cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    // MARK: - Run-resync erase-length decision

    /// Pure decisions extracted from `swapLastWordInBuffer`'s erase-length
    /// override so they're directly unit-testable without a live AX element
    /// (same rationale as `shouldWarnSlowCallback` below).
    ///
    /// Safe direction: the AX-measured screen word is SHORTER than modelled
    /// — always adopt it. Erasing less than the model never eats real text;
    /// the worst case is a stray character that self-heals on the next
    /// correction (the "ccccara"/"cchr" class this replaced).
    static func shouldClampToScreen(model: Int, measured: Int) -> Bool {
        measured < model
    }

    /// Dangerous direction: the screen measured LONGER than modelled. Only
    /// adopt it when there's proof the extra characters are OUR OWN
    /// artifact (an overlay's autocomplete/predictive text) and not real
    /// text the user already had: the measured word must literally end with
    /// what we typed, and the gap must be small — an overlay drops at most
    /// a couple of keystrokes, it doesn't insert a whole extra word.
    static func shouldExtendToScreen(
        model: Int, measured: Int, modelWord: String, screenWord: String
    ) -> Bool {
        guard measured > model, measured - model <= 2, !modelWord.isEmpty else { return false }
        guard screenWord.hasSuffix(modelWord) else { return false }
        // Field 10.09.2026 (`net=-1`): "r" typed in en, layout switched
        // externally, "у" typed in ru, Double Shift — the screen word "rу"
        // ends with the modelled "у", so the erase was widened to 2 while the
        // payload came from the 1-key buffer and the user's own "r" was eaten.
        // A dropped-keystroke artifact repeats OUR typing, i.e. letters of
        // the same script as the model; a different script (or a non-letter)
        // in the extra prefix is text the user already had — asymmetry rule:
        // keep the modelled length and leave a stray character behind rather
        // than erase real text.
        let extra = String(screenWord.dropLast(modelWord.count))
        guard !extra.isEmpty, extra.allSatisfy(\.isLetter) else { return false }
        return !LanguageDetector.isMixedScript(extra + modelWord)
    }
}
