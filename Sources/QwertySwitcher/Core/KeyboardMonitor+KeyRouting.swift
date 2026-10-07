import Foundation
import CoreGraphics
import AppKit
import Darwin

extension KeyboardMonitor {
    // MARK: - Event Handling

    /// Internal (not fileprivate) so the headless test harness in
    /// TestRunner.swift can exercise the exact queue/skip contract directly.
    func queueIfReplacementActive(_ event: KeyEventSnapshot) -> Bool {
        guard isPaused, event.route == .physical else { return false }
        // Modifier transitions (Shift/Cmd/Option/CapsLock) are deliberately
        // NEVER queued for replay — root cause of the "avalanche" incident
        // (see `CorrectionAvalancheGuard`): a real Shift down/up captured here and replayed later,
        // all at once right as the pause ends, arrives at
        // `HotkeyManager.handleFlagsChanged` with squashed, non-human timing.
        // Its Shift-tap gesture detector times taps in real wall-clock terms
        // — fed a replayed burst it can register a false Double Shift, which
        // fires another correction, whose own pause queues the NEXT physical
        // shift transition, and so on. Each queued keyDown/keyUp already
        // carries its own flags snapshot (`KeyEventSnapshot.flags`), so the
        // target app doesn't need a correctly-ordered flagsChanged replay to
        // render correctly — letting real modifier transitions pass through
        // live (unsuppressed, analyzed with their true timing) costs nothing
        // and removes the fuse.
        guard event.type != .flagsChanged else { return false }
        pendingUserEvents.enqueue(event)
        return true
    }

    /// Read-and-reset the trigger-suppression flag. Called by the event tap
    /// callback exactly once, right after `handleEvent` returns, so it never
    /// leaks into an unrelated later event. Internal (not fileprivate) so the
    /// headless integration-test harness in TestRunner.swift can replicate
    /// the same tap-callback contract without a real CGEventTap.
    func consumeSuppressCurrentEvent() -> Bool {
        defer { suppressCurrentEvent = false }
        return suppressCurrentEvent
    }

    /// Single choke point for "hotkeys must not fire right now" in this file
    /// — per-app profile block (existing) OR the frontmost app being in Game
    /// Mode (gamemode-spec-20260831.md §2: Single/Double/L+R Shift and
    /// Cmd+Opt+Z all silenced in-game, same as `HotkeyManager`'s own
    /// wrapper of the same name). Every direct call to the per-app-profile
    /// check in this file routes through here — kept as its own tiny method
    /// rather than reaching into `HotkeyManager` (weak optional, different
    /// owner, and not always wired — see `KeyboardMonitorHarness`) just to
    /// share one line.
    private func hotkeysBlocked() -> Bool {
        exceptionsService.areHotkeysBlockedForCurrentApp() || gameMode.isActive(bundleID: activeAppBundleID)
    }

    func handlesShortcut(_ event: KeyEventSnapshot) -> Bool {
        let keycode = event.keycode
        if event.type == .flagsChanged && keycode == 57 {
            return prefsService.isCapsLockSwitchEnabled && !hotkeysBlocked()
        }
        guard event.type == .keyDown else { return false }
        let flags = event.flags
        if flags.contains(.maskCommand) && flags.contains(.maskShift) && flags.contains(.maskAlternate) && keycode == 9 {
            return prefsService.isPasteNoFormatEnabled
                && !hotkeysBlocked()
                && NSPasteboard.general.string(forType: .string) != nil
        }
        return flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
            && keycode == 6
            && switchUndoManager.canUndo
            && !hotkeysBlocked()
    }

    /// Compatibility adapter over `handle(_:)`, kept internal (not
    /// fileprivate) in case anything still calls the tap-callback shape
    /// directly with a raw CGEvent. `eventTapCallback` and the test harness
    /// call `handleTapDisabled`/`handle(_:)` directly instead — this only
    /// builds the one `KeyEventSnapshot` they would otherwise build themselves.
    func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
            handleTapDisabled(type)
            return
        }
        handle(KeyEventSnapshot(type: type, event: event))
    }

    /// The tap-disabled branch of the old combined `handleEvent`, extracted
    /// so `eventTapCallback` can call it directly for a disable notification
    /// without building a `KeyEventSnapshot` from an event that carries no
    /// real keystroke fields.
    func handleTapDisabled(_ type: CGEventType) {
        if type == .tapDisabledByTimeout { tapTimeoutDisableCount += 1 }
        DebugLog.shared.log(
            "KM",
            "event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) — re-enabling"
                + (type == .tapDisabledByTimeout ? " count=\(tapTimeoutDisableCount)" : "")
        )
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            health = secureInputDetector.isSecureInput ? .secureInput : .running
        } else {
            health = .unavailable
        }
    }

    /// The real keystroke hot path — everything the old `handleEvent` did
    /// once past the tap-disabled branch, driven purely off
    /// `KeyEventSnapshot`'s scalar fields (no CGEvent reads left below this
    /// point in the file — see `KeyEventSnapshot.init(type:event:)`).
    /// Internal (not fileprivate) so the headless integration-test harness in
    /// TestRunner.swift can drive it directly — same code path
    /// `eventTapCallback` uses, minus the tap plumbing itself.
    func handle(_ event: KeyEventSnapshot) {
        // Generated events carry a process-local marker. Unlike the old 300ms
        // cooldown, this filters only our own synthetic keystrokes (backspace/
        // retype) — replayed real keystrokes route as `.replayedUser` and are
        // analyzed exactly like live typing (RC-2: a replayed space must still
        // clear the buffer at a word boundary instead of bypassing analysis).
        if event.route == .ours { return }

        // Proof of life for the avalanche circuit breaker: a genuinely
        // physical event (not one we replayed from the pause queue) resets
        // the "consecutive auto-fires with no human action" counter. Placed
        // before any branch that can fire a correction, so it always applies
        // regardless of which path below eventually runs.
        if event.route != .replayedUser {
            avalancheGuard.registerPhysicalEvent()
        }

        if event.type == .flagsChanged {
            lastEventWasLetter = false // plan 013 C: a modifier event after the letter voids the first-burst retype
            hotkeyManager?.handleFlagsChanged(keycode: UInt16(event.keycode), flags: event.flags)
            // AFTER the hotkey manager: its fresh Shift-down clears the per-cycle tap
            // suppression, so the "this Shift is not a bare tap" mark must come last (plan 013 B).
            noteChordCommaFlags(keycode: UInt16(event.keycode), flags: event.flags)
            return
        }

        guard event.type == .keyDown else { return }
        lastEventWasLetter = false // plan 013 C: set again only by the buffered-letter append below
        keyDownsSinceActivation += 1
        // Any keyDown voids a pending chord candidate (a later key means the "." was a period).
        // This single line covers backspace, navigation keys, secure input and every ordinary
        // key; `kc44` re-arms it at the end of its own branch below.
        chordComma = nil

        let keycode = event.keycode
        let flags = event.flags

        // Cmd+Option+Shift+V
        if flags.contains(.maskCommand) && flags.contains(.maskShift) && flags.contains(.maskAlternate) && keycode == 9 {
            // Ghost shift-tap fix: mark the key as pressed BEFORE anything
            // else in this branch, whether or not the feature is enabled or
            // even fires. Without this, Cmd↓→Shift↓→V(swallowed)→Shift↑
            // looked exactly like a clean Shift-tap gesture to
            // `HotkeyManager`, arming a phantom Double/Single Shift on the
            // NEXT shift-tap within its 450ms window.
            hotkeyManager?.markKeyPressed()
            if hotkeysBlocked() {
                invalidateEditingContext(reason: "blocked-app-hotkey")
                return
            }
            var started = false
            if prefsService.isPasteNoFormatEnabled {
                isPaused = true
                started = hotkeyManager?.handlePasteNoFormat { [weak self] in
                    self?.finishReplacement()
                } ?? false
                if !started { isPaused = false }
            }
            DebugLog.shared.log(
                "KM", "pasteNoFormat: swallowed enabled=\(prefsService.isPasteNoFormatEnabled) started=\(started)"
            )
            // Every pass through this branch — feature disabled, pasteboard
            // empty, or a real substitution — can end with the on-screen
            // text changed underneath our buffer/runKeystrokes/lastCompletedWord
            // model (either our own synthetic paste, or the real Cmd+Shift+V
            // reaching the app because it wasn't swallowed). `isPaused==true`
            // defers this to `finishReplacement` via `invalidateAfterReplacement`
            // (same mechanism other replacement paths use); otherwise it
            // clears immediately.
            invalidateEditingContext(reason: "paste-no-format")
            return
        }

        // Cmd+Option+Z → undo last switch
        // (Plain Cmd+Z is left to the host app to avoid conflicting with its own undo stack.)
        if flags.contains(.maskCommand) && flags.contains(.maskAlternate)
            && keycode == 6 && switchUndoManager.canUndo
            && !hotkeysBlocked() {
            _ = undoLastCorrection()
            return
        }

        hotkeyManager?.markKeyPressed()
        perAppLayoutService.rememberCurrentLayout(bundleID: activeAppBundleID)

        // Secure fields are never buffered, including while auto-switch is off.
        if secureInputDetector.isSecureInput {
            // A secure field is a new context: no sentence start / island ring carries over.
            // Mechanism B reset point 3/7: secure input.
            resetTypingContext(.secureInput)
            health = .secureInput
            DebugLog.shared.log("KM", "skip: secure input")
            return
        }
        if health != .running { health = .running }

        // Stale buffer eviction — user paused typing too long, old keys don't belong to current word
        let now = CFAbsoluteTimeGetCurrent()
        if (!buffer.isEmpty || !pendingLeadingSymbols.isEmpty || !runKeystrokes.isEmpty)
            && (now - lastKeyTime) > staleBufferTimeout {
            // Mechanism B reset point 4/7: stale-buffer eviction (10s idle).
            resetTypingContext(.stale(seconds: Int((now - lastKeyTime).rounded())))
        }
        lastKeyTime = now

        // Spotlight used to be excluded from auto-correction. The exclusion had
        // no recorded reason (investigated 04.08.2026 — git history goes back
        // only to the squashed backup commit) and was kept out of caution about
        // its live incremental search. Removed 08.08.2026 on the owner's report:
        // typing "sw" there showed "ыц" and stayed that way, which is precisely
        // the case this app exists for — and Spotlight is where a wrong-layout
        // query is most useless, since it returns nothing at all.
        //
        // The frontmost-app lookup is gone with it: it ran on every keystroke
        // and now buys nothing.
        if InputBuffer.isModifierActive(flags) {
            if InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: flags) {
                invalidateEditingContext(reason: "modifier-shortcut")
            }
            return
        }
        let appProfile = activeAppBundleID.flatMap { exceptionsService.profile(for: $0) }
        // Game mode (gamemode-spec-20260831.md §2): a single point in
        // `canAutoCorrect` silences boundary correction, instant correction,
        // snippets, smart case and Mechanism C's frequency bump all at once —
        // every one of them is already gated behind this flag (see the
        // `else if` branches below and the `.noSwitch` bump call).
        let gameActive = gameMode.isActive(bundleID: activeAppBundleID)
        let canAutoCorrect = prefsService.isAutoSwitchEnabled
            && appProfile?.blockAutoSwitch != true
            && !gameActive

        if InputBuffer.isDeleteKey(keycode) {
            if !pendingLeadingSymbols.isEmpty || lastCompletedWord != nil {
                logContextWipe("backspace")
            }
            // Nothing of the current word left to delete = the backspace eats
            // what came before it. With no leading symbols pending that is the
            // gap or the very period that armed smart case ("спасиб." ⌫ "о."
            // came out "спасибО.", "готово." ⌫ " теперь" → "Теперь"; field
            // log 22.09.2026, synthetic examples). A pending "." or "(" is safe
            // to lose; pending digits are not — the run is dropped wholesale
            // below, and whatever digits stay on screen still open the sentence.
            if buffer.isEmpty, pendingLeadingSymbols.isEmpty || pendingLeadHasDigit {
                sentenceStartTracker.reset()
            }
            buffer.removeLast()
            autoLearnTracker.registerDeletion()
            // Conservative: we can't tell from here whether the deleted
            // character was a letter or one of the tracked leading symbols,
            // so the run is dropped entirely rather than risk an over/under
            // backspace count on a later correction. The same reset also clears
            // history and the undo record.
            // Mechanism B reset point 5/7: backspace.
            // Bug fix (bugfixes-diag-20260831.md Bug B): the buffer isn't
            // necessarily empty after a backspace (only its LAST keystroke
            // was dropped), so the ordinary `buffer.isEmpty` → `startNewWord()`
            // path below never runs here — without the instant-gate reset in
            // this scope, an instant correction earlier in the same word left
            // `wasCorrected == true` and silently gated the eventual
            // word-boundary evaluation too ("skip boundary correction:
            // already instant-corrected" on a word the owner had since edited
            // by hand).
            resetTypingContext(.backspace)
            return
        }

        if InputBuffer.isWordBoundary(keycode) {
            // Captured before the reset right below — `handleWordBoundary`
            // needs "did THIS word have any held-key autorepeats" for the
            // game-mode prose-exit signal (spec §5) and the actual count for
            // `processCurrentWord`'s own held-keys gate (bug: that gate used
            // to read `self.wordAutorepeatCount` directly, which by the time
            // it ran had already been zeroed right here for the NEXT word —
            // the gate could never fire on this path), and by the time
            // either runs the counter has already been zeroed for the NEXT
            // word.
            let autorepeatCountAtBoundary = wordAutorepeatCount
            let wordHadHeldKeys = autorepeatCountAtBoundary > 0
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            let correctable = InputBuffer.isCorrectableBoundary(keycode)
            handleWordBoundary(
                trailing: correctable ? " " : nil,
                canAutoCorrect: canAutoCorrect && correctable,
                keepForManualSwitch: correctable,
                triggerEvent: event,
                wordHadHeldKeys: wordHadHeldKeys,
                wordAutorepeatCount: autorepeatCountAtBoundary,
                proseBoundary: true
            )
            return
        }

        // Recorded before the branches below, so the run keeps every printable
        // keystroke regardless of how the scoring buffer chooses to slice it.
        if InputBuffer.isLetterKey(keycode) || InputBuffer.isNumberOrSpecial(keycode) {
            runKeystrokes.append(BufferedKeystroke(keycode: keycode, flags: flags))
            // Game mode `longRun` evidence (spec §5 table): a run this long
            // with no word boundary at all is near-exclusively a game
            // control spree — measured 0 occurrences outside game windows
            // (max run 29, n=309) vs 57 inside (max 260, n=599). One-shot:
            // this line runs exactly once as the count crosses 32, not on
            // every keystroke after. `isGameControlRun` (06–08.09.2026 field
            // incident) excludes digits/`/`/`-`/`=`/ambiguous-letter runs —
            // those are URLs, paths, tokens, passwords, never game evidence.
            if runKeystrokes.count == 32, InputBuffer.isGameControlRun(runKeystrokes) { gameMode.note(.longRun) }
            // Field-debugging trace ("Подробный лог"): which keystroke stopped
            // growing the run. buf is pre-append for the letter path below.
            // Restored 19.09.2026 on the owner's decision: 0.11.1 dropped it
            // for privacy and took word-level field analysis down with it —
            // without these lines a verbose log cannot answer "was that
            // correction a real word or junk", which is the one question the
            // log exists for. The log stays owner-only on disk (0700/0600)
            // and the exported report still strips these lines
            // (`DiagnosticsExportService.filterReportLog`), so nothing typed
            // leaves this Mac.
            DebugLog.shared.log(
                "KM",
                "key kc=\(keycode) run=\(runKeystrokes.count)"
                    + " buf=\(buffer.currentWord().count) lead=\(pendingLeadingSymbols.count)",
                level: .verbose
            )
        }

        // Context-aware punctuation: e.g. `.` `,` `;` `'` produce real letters in
        // Russian layout (ю, б, ж, э) but punctuation in English. Treat them as a
        // word boundary only when current layout is Latin.
        let currentLayout = languageDetector.inputSourceManager.currentLayout
        let currentLang = currentLayout?.languageCode
        // These keys carry a LETTER in the other alphabet (`;`=ж `,`=б `.`=ю
        // `[`=х `]`=ъ `'`=э `` ` ``=ё), and 39.6% of Russian words ≥3 letters
        // contain at least one of them — measured on the bundled dictionary.
        // Closing the word here decided, irreversibly and at the moment of the
        // keystroke, something only the FOLLOWING characters can settle: "так;"
        // got corrected on its own and "е" landed in the next word ("до так;е",
        // owner 05.08). So the key now joins the run and the decision is
        // deferred to the real boundary, where `LanguageDetector.projections`
        // weighs both readings against the dictionary.
        let punctuationRunsOn = InputBuffer.isLetterKey(keycode)
        if !punctuationRunsOn,
           InputBuffer.isPunctuationIn(keycode: keycode, languageCode: currentLang, flags: flags) {
            let punctChar = currentLayout.flatMap {
                languageDetector.inputSourceManager.characterForKeycode(
                    keycode, layout: $0, flags: flags
                )
            } ?? InputBuffer.punctuationChar(
                keycode: keycode, languageCode: currentLang, flags: flags
            ) ?? ""
            // Captured before the reset right below, same reason as the
            // word-boundary branch above — and reset here too so a punctuation
            // close doesn't leak this word's autorepeat count into the next one.
            let autorepeatCountAtBoundary = wordAutorepeatCount
            wordAutorepeatCount = 0
            handleWordBoundary(
                trailing: punctChar,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true,
                triggerEvent: event,
                wordAutorepeatCount: autorepeatCountAtBoundary
            )
            return
        }

        if InputBuffer.isLetterKey(keycode) {
            switchUndoManager.invalidate()
            autoLearnTracker.registerNonDeletion()
            // Cheap flag check first: the keycode→character lookup runs only while an island of an
            // already finished word is pending.
            if pendingIslandRestore && pendingIslandOwnerEnded {
                cancelStalePendingIsland(keycode: keycode, flags: flags, layout: currentLayout)
            }
            if buffer.isEmpty {
                lastCompletedWord = nil
                lastAmbiguousKeyIndex = nil
                lastLoggedInstantSilence = nil
                instantCorrectionGate.startNewWord()
                bufferTypedLayoutID = currentLayout?.id
            } else if bufferTypedLayoutID != currentLayout?.id {
                bufferTypedLayoutID = nil // letters from two layouts: no first-burst retype
            }
            buffer.append(keycode, flags: flags)
            lastEventWasLetter = true
            // Game mode `heldKeys` evidence (spec §5 table): counts letters
            // that landed with the OS autorepeat flag set — a game control
            // held down, not a human typing. Reset alongside `runKeystrokes`/
            // `buffer` at all 7 sites above.
            if event.autorepeat != 0 { wordAutorepeatCount += 1 }
            if InputBuffer.isAlphabetAmbiguous(keycode) { lastAmbiguousKeyIndex = buffer.count }
            // Instant correction fires MID-word, before the evidence is in. It
            // has its own, looser scorer, so while an alphabet-ambiguous key is
            // still within the last 2 keystrokes it can misread pure punctuation
            // as a letter: "key." reads as the Russian word "луню" and got
            // replaced while still being typed. The run waits for the real word
            // boundary (full projection logic) until 2 plain letters have
            // followed the ambiguous key — by then its alphabet is settled and
            // it no longer needs to poison the rest of the word. Pure letter
            // runs behave exactly as they did before.
            if canAutoCorrect && prefsService.isInstantCorrectionEnabled
                && appProfile?.blockInstantCorrection != true {
                if instantCorrectionGate.wasCorrected {
                    logInstantSilence(.alreadyCorrected, len: buffer.count)
                } else if autoLearnTracker.isAwaitingRetype, autoLearnTracker.isRetypePrefix(
                    // Checked first: the conversion below would otherwise run on every letter.
                    languageDetector.lastConvertedWord(keystrokes: buffer.currentWord()) ?? ""
                ) {
                    // The user deleted a correction and is retyping the original: leave it alone.
                    if buffer.count >= InstantCorrectionAnalyzer.minLength {
                        DebugLog.shared.log("KM", "instant silent: gate=awaitingRetype len=\(buffer.count)", level: .verbose)
                    }
                } else if ambiguousKeyRecent {
                    logInstantSilence(.ambiguousKeyRecent, len: buffer.count)
                } else if wordAutorepeatCount >= 3 {
                    // Game mode gate (spec §5): ≥3 held-key autorepeats in
                    // this word is itself a behavioral clue, on top of
                    // silencing this fire.
                    gameMode.note(.heldKeys)
                    logInstantSilence(.heldKeys, len: buffer.count)
                } else {
                    tryInstantCorrection(triggerEvent: event)
                }
            }
        } else if InputBuffer.isNumberOrSpecial(keycode) {
            switchUndoManager.invalidate()
            guard !buffer.isEmpty else {
                // A layout-dependent symbol with no letters typed yet (leading
                // "$"/"#"/"@"/"/" etc.) belongs to whatever word starts right
                // after it — track it instead of treating it as the trailing
                // of an empty (uncorrectable) word, where it was structurally
                // unreachable for correction ("$GRAF", "/model").
                //
                // The history slot dies here, exactly like it does on the
                // letter path above. Double Shift's history fallback rewrites
                // text at the CARET, so it is only sound while the caret still
                // sits right after that word — one digit typed since, and the
                // backspaces eat the wrong characters. Owner hit this typing
                // "на 300$": Double Shift converted the stale "на" and retyped
                // it at the caret, producing "на 30yf" (log 08:26:04,
                // "doubleShift via history: ru→en len=2", with lead=4 digits
                // already sitting in front of it).
                lastCompletedWord = nil
                pendingLeadingSymbols.append(BufferedKeystroke(keycode: keycode, flags: flags))
                armChordCommaIfEligible(keycode: keycode, flags: flags, canAutoCorrect: canAutoCorrect)
                return
            }
            let digit = languageDetector.inputSourceManager.trailingCharacter(
                keycode: keycode, flags: flags
            ) ?? ""
            // Same capture-then-reset as the punctuation branch above — a
            // digit boundary must not leak this word's autorepeat count
            // into the next one either.
            let autorepeatCountAtBoundary = wordAutorepeatCount
            wordAutorepeatCount = 0
            handleWordBoundary(
                trailing: digit,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true,
                triggerEvent: event,
                triggerKeystroke: BufferedKeystroke(keycode: keycode, flags: flags),
                wordAutorepeatCount: autorepeatCountAtBoundary
            )
            armChordCommaIfEligible(keycode: keycode, flags: flags, canAutoCorrect: canAutoCorrect)
        } else {
            // The caret moved: the sentence start before it is no longer the one before the next word.
            // Mechanism B reset point 6/7: navigation keys.
            resetTypingContext(.navigationKey(keycode))
        }
    }

    func finishReplacement() {
        isPaused = false
        // Applies to instant/boundary auto-correction only (see
        // `canFireAutoCorrection`) — set unconditionally here (every
        // replacement path funnels through this one function) so even a
        // manual Double Shift/Undo/Yoficator run imposes the same brief
        // settling window before the NEXT automatic correction is allowed.
        autoCorrectionCooldownUntil = CFAbsoluteTimeGetCurrent() + autoCorrectionCooldownInterval
        if invalidateAfterReplacement {
            invalidateAfterReplacement = false
            invalidateEditingContext()
        }
        drainPendingUserEvents()
    }

    /// Hands every key queued during the pause back to the app, analysing each
    /// one first exactly as `eventTapCallback` does for a live key (see
    /// `replaySink` for why the posted event cannot do that itself). FIFO.
    ///
    /// - A replacement is active again (an earlier replayed key started one —
    ///   e.g. a queued Cmd+Option+Z): the loop stops and everything behind
    ///   stays queued, to drain at that replacement's own
    ///   `finishReplacement`. Analysing them now would run the next word's
    ///   keys through `handle` while the screen is mid-rewrite, and the
    ///   replacement's completion (it clears `buffer`) would swallow them.
    /// - `.ours` (a failed replacement's restored trigger, `asOurs`) is
    ///   delivered only, never analysed — the tap passes `.ours` through too.
    /// - Anything else: shortcut check, `handle` as `.replayedUser` (skips the
    ///   avalanche guard's proof-of-life), then deliver unless it was
    ///   suppressed. The post-replacement cooldown set in `finishReplacement`
    ///   keeps a replayed burst from starting an automatic correction here;
    ///   the re-queue rule above is the safety net for the paths it does not
    ///   cover (shortcuts, Double Shift).
    private func drainPendingUserEvents() {
        // Re-entrancy: a replayed key can start a replacement that completes synchronously (a
        // headless fake does) and calls `finishReplacement` from inside `handle` below. The
        // running loop already picks up the rest in order; a nested drain would deliver later
        // keys BEFORE the one being analysed.
        guard !isDrainingPendingEvents else { return }
        isDrainingPendingEvents = true
        defer { isDrainingPendingEvents = false }
        // One key at a time, straight off the queue: everything not yet analysed STAYS queued
        // while the current key is handled, so guards that read `pendingUserEvents.isEmpty`
        // (the island restore's "the owner is already typing" check) see the real backlog.
        // A replacement active again ends the loop; the rest simply stays queued and drains at
        // that replacement's own `finishReplacement`.
        while !isPaused, let snapshot = pendingUserEvents.popFront() {
            if snapshot.route == .ours {
                replaySink(snapshot)
                continue
            }
            let suppressHandledShortcut = handlesShortcut(snapshot)
            handle(snapshot.asReplayed)
            let suppressTrigger = consumeSuppressCurrentEvent()
            if !(suppressHandledShortcut || suppressTrigger) { replaySink(snapshot) }
        }
    }
}
