import Foundation
import CoreGraphics
import AppKit

final class KeyboardMonitor {
    private struct QueuedUserEvent {
        let type: CGEventType
        let keycode: CGKeyCode
        let flags: CGEventFlags
        let autorepeat: Int64
        let keyboardType: Int64

        init(type: CGEventType, event: CGEvent) {
            self.type = type
            keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            flags = event.flags
            autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            keyboardType = event.getIntegerValueField(.keyboardEventKeyboardType)
        }

        func makeEvent() -> CGEvent? {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keycode,
                keyDown: type != .keyUp
            ) else { return nil }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            SyntheticEventMarker.markAsReplayedUserEvent(event)
            return event
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private let buffer = InputBuffer()
    private let languageDetector: LanguageDetector
    private let textReplacer: TextReplacing
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    private let exceptionsService: ExceptionsService
    private let yoficatorService: YoficatorService
    private let switchUndoManager: SwitchUndoManager
    private let perAppLayoutService: PerAppLayoutService
    private let instantCorrectionAnalyzer: InstantCorrectionAnalyzer
    private let snippetService: SnippetService
    private var sentenceStartTracker = SentenceStartTracker()
    private var instantCorrectionGate = InstantCorrectionGate()
    private let secureInputDetector: SecureInputDetector
    private let permissionsService = PermissionsService()
    private var activeAppBundleID: String?
    var hotkeyManager: HotkeyManager?
    private(set) var isRunning = false
    private(set) var health: EventTapHealth = .stopped {
        didSet {
            guard health != oldValue else { return }
            NotificationCenter.default.post(name: .eventTapHealthChanged, object: self)
        }
    }
    var isPaused = false
    private var pendingUserEvents = PendingUserEventQueue<QueuedUserEvent>()
    private var invalidateAfterReplacement = false

    /// Everything printable typed since the last real break — letters, digits
    /// and symbols alike, in the order they were pressed. Only Double Shift
    /// reads it, and only when the run contains something the dictionary
    /// cannot judge.
    ///
    /// `buffer` is deliberately letters-only: automatic correction has to score
    /// a word, and "7ю6с" is not a word. But the user pressing Double Shift on
    /// "7ю6с" is not asking for a judgement — they are pointing at what is on
    /// screen and saying "this, in the other alphabet" (`7.6s`). That gesture
    /// needs the raw run, so it gets its own track instead of bending the
    /// scoring buffer into something it was never meant to hold.
    private var runKeystrokes: [BufferedKeystroke] = []

    /// Set by `convertWholeRun` when it measured the real on-screen text for
    /// a letters-only run (AX resync) and then fell through — a pure word is
    /// this function's business to convert, not judge, so it hands the
    /// measurement to the scored path in `swapLastWordInBuffer` right after
    /// it returns. Without this the measurement was computed and thrown
    /// away, and the scored path re-derived the erase count from the model
    /// that had just disagreed with the screen — the Spotlight
    /// "ccccara"/"cchr" class: every swap erased one character too few and
    /// the survivor stacked up on the left. Reset at the top of every
    /// `convertWholeRun` call and consumed once by `swapLastWordInBuffer`.
    private var pendingRunResync: Int?

    /// The screen word measured alongside `pendingRunResync` above — needed
    /// separately because deciding whether to trust a LONGER measurement
    /// requires seeing the actual characters (does the screen word end with
    /// what we typed?), not just comparing two counts. Same lifecycle as
    /// `pendingRunResync`: set together, cleared together.
    private var pendingRunResyncWord: String?

    // Avalanche circuit breaker (see CorrectionAvalancheGuard) — applies only
    // to the two fully-automatic correction entry points (instant + word
    // boundary). Double Shift is intentionally NOT gated by either of these:
    // it fires only from an individually-timed physical Shift-tap gesture,
    // and rapid manual re-presses (toggle back and forth on the same word)
    // are an existing, tested feature with no artificial delay.
    // internal(set) so KeyboardMonitorHarness-based tests can observe that
    // the guard is actually wired into the real correction path (not just
    // exercise the pure struct in isolation).
    private(set) var avalancheGuard = CorrectionAvalancheGuard()
    private var autoCorrectionCooldownUntil: CFAbsoluteTime = 0
    private let autoCorrectionCooldownInterval: CFAbsoluteTime = 0.2

    /// Count of `.tapDisabledByTimeout` events seen this run — a live-log
    /// counter (task: "защита от повторения") so a regression shows up as a
    /// rising number, not just individual log lines a human has to notice.
    private(set) var tapTimeoutDisableCount = 0

    private let callbackWarnThreshold: CFAbsoluteTime = 0.015 // 15ms
    // Set synchronously while handling a keydown we've decided to suppress
    // (its trigger races with our own backspaces — RC-1). Consumed exactly
    // once by the event tap callback right after `handleEvent` returns.
    private var suppressCurrentEvent = false

    private var autoLearnTracker = AutoLearnTracker()

    // MARK: - Learning on behavior patterns (learning_spec.md, wave 2)

    /// Mechanism A (DS-confirmed pairs), C (passive personal frequency) and
    /// B (revert/toggle classification) — owned here, the only place that
    /// touches all six Double Shift success sites (3 in this file, 3 more in
    /// `HotkeyManager` via `classifyDoubleShiftGesture`) plus both automatic
    /// correction success callbacks and `undoLastCorrection`. Default-valued
    /// so `AppDelegate`'s existing `KeyboardMonitor(...)` call site is
    /// untouched — these three modules are entirely self-contained
    /// (UserDefaults-backed, like `PreferencesService`).
    // Visibility only (wave 3, orchestrator-approved) — `ExceptionsViewModel`
    // and `SettingsBackupService` need the SAME live instances this class
    // owns (a second `LearnedWordsStore()`/`PersonalFrequencyStore()` would
    // be an independent in-memory copy racing this one). Contract/behavior
    // unchanged: still only ever mutated from within this file.
    let learnedWordsStore: LearnedWordsStore
    let personalFreqStore: PersonalFrequencyStore
    private let feedbackTracker: CorrectionFeedbackTracker
    private var learningFlushTimer: Timer?
    private let learningFlushInterval: TimeInterval = 30

    // MARK: - Game mode (gamemode-spec-20260831.md, wave 2)

    /// `.shared` singleton by default — same DI seam as `learnedWordsStore`
    /// above, but this one needs no cross-instance sharing (wave 3's UI reads
    /// `GameModeState.shared` directly), so it stays `private`.
    private let gameMode: GameModeState

    /// Autorepeat keystrokes seen in the run/word currently being buffered
    /// (spec §5 `heldKeys` evidence). Reset at every point that resets
    /// `runKeystrokes`/`buffer` (7 sites, see `runKeystrokes.removeAll()`).
    /// Hot-path: a plain increment on a value already read off the CGEvent —
    /// no UserDefaults/Bundle/NSWorkspace call.
    private var wordAutorepeatCount = 0

    // Stale-buffer eviction: drop accumulated keys if user paused typing too long
    private var lastKeyTime: CFAbsoluteTime = 0
    private let staleBufferTimeout: CFAbsoluteTime = 10.0 // 10 sec idle → clear

    // Last completed word (for Double Shift fallback after space).
    // When user types "ghbdtn " and then hits Double Shift, the main buffer is
    // already empty — we pull keycodes from here instead.
    // `typedLayout` is the layout that was ACTUALLY active while these
    // keycodes were typed/produced — captured at the moment this tuple is
    // written, never re-derived from "whatever is active now" when Double
    // Shift is eventually pressed (this history has no TTL, so the active
    // layout can easily have drifted by then — see CLAUDE.md "марже" bug).
    private var lastCompletedWord: (
        keystrokes: [BufferedKeystroke], trailing: String, typedLayout: KeyboardLayout,
        // Layout-dependent symbols typed right before this word (e.g. "/" in
        // "/exit"), captured alongside so Double Shift's history fallback
        // can fold them into the SAME transaction — see `pendingLeadingSymbols`.
        leadingSymbols: [BufferedKeystroke],
        // The keycode+flags that rendered `trailing` — a physical key can
        // print a DIFFERENT character per layout (Shift+kc44 = '?' in
        // QWERTY, ',' in ЙЦУКЕН). Kept so the history fallback in
        // `swapLastWordInBuffer` can re-render the trigger for whatever
        // layout it is about to convert INTO, instead of replaying the
        // string captured on the layout it was typed on. Nil for triggers
        // with no single originating keystroke (space, re-armed history).
        trailingKeystroke: BufferedKeystroke?
    )?

    // Layout-dependent symbols typed with an empty letter buffer (leading
    // "$"/"#"/"@"/"/" etc., e.g. "$GRAF", "/model") belong to whichever word
    // starts right after them. Tracked SEPARATELY from `buffer` — which stays
    // letter-only so detect()/Double Shift/Yoficator scoring is completely
    // unaffected — and folded into the same backspace+retype transaction only
    // when a correction actually fires. Reset at every boundary/deletion/
    // context-invalidation so a stale run can never cause a wrong backspace
    // count. Trailing symbols (after the word, before the boundary) are left
    // out of scope for now — see Fix report.
    private var pendingLeadingSymbols: [BufferedKeystroke] = []

    /// Position (1-based `buffer.count` right after it was appended) of the
    /// most recent alphabet-ambiguous key — a letter in one alphabet and
    /// punctuation in the other, see `InputBuffer.isAlphabetAmbiguous` — in
    /// the word currently being buffered. `nil` once no such key has been
    /// typed yet for this word. Recomputed every keystroke rather than
    /// latched for the whole word — see `ambiguousKeyRecent`.
    private var lastAmbiguousKeyIndex: Int?

    /// De-dup key for `logInstantSilence` — the same silence reason is
    /// written at most once per word, right when it FIRST applies, instead
    /// of once per keystroke. Without this a 12-letter internal word would
    /// write the same `gate=ownIsWord` line 9 times, roughly doubling the
    /// log's write rate for zero extra signal. Reset alongside
    /// `lastAmbiguousKeyIndex` whenever a new word starts.
    private var lastLoggedInstantSilence: InstantCorrectionAnalyzer.SilenceReason?

    /// True while an alphabet-ambiguous key is still within the last
    /// keystroke of the buffered word — i.e. no plain letter has followed
    /// it yet. Instant correction has its own, looser scorer than the
    /// word-boundary path, so right as the ambiguous key lands ("key."
    /// reads as the real Russian word "луню" the instant "." lands), it
    /// must wait for the boundary. Once even 1 more letter has been typed,
    /// the run is overwhelmingly one alphabet or the other and instant
    /// correction may resume — unlike a sticky flag, this stays accurate
    /// for a key that happens to sit in the MIDDLE of a long word.
    ///
    /// Narrowed from "last 2 keystrokes" to "last 1" on 21.08.2026: the
    /// real field corpus (Scripts/research/kc_trace_words.py, 26h trace)
    /// found this gate was the 2nd-largest cause (31% of samples, after the
    /// junk-gate's 62%) of instant staying silent on words the boundary
    /// path then had to fix. The 1-key width was measured to add ZERO new
    /// false positives (instant_minlen_sim.py measures 1/1b/2/2b unchanged
    /// at minLength=4; instant_junk_gate_sim.py's FP-protection measures
    /// 3/4 unchanged) while improving en→ru recall (measure [2]: 2257→2227
    /// words newly fire instantly instead of waiting for the boundary, all
    /// of them recoverable there anyway — zero hard loss either way). The
    /// "key." test (TestRunner.swift) still passes: the ambiguous key
    /// itself is always its own most-recent keystroke (diff=0), which
    /// blocks under any window ≥1.
    private var ambiguousKeyRecent: Bool {
        guard let idx = lastAmbiguousKeyIndex else { return false }
        return buffer.count - idx < 1
    }


    init(languageDetector: LanguageDetector, textReplacer: TextReplacing,
         statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, yoficatorService: YoficatorService,
         switchUndoManager: SwitchUndoManager, perAppLayoutService: PerAppLayoutService,
         instantCorrectionAnalyzer: InstantCorrectionAnalyzer,
         snippetService: SnippetService = SnippetService(),
         // Defaults to the real system check — only the headless integration
         // harness in TestRunner.swift overrides it, to stay deterministic
         // regardless of whatever secure-input state the Mac running the
         // tests happens to be in (IsSecureEventInputEnabled is a GLOBAL OS
         // flag, unrelated to this test process).
         secureInputDetector: SecureInputDetector = SecureInputDetector(),
         // Defaulted (see the property doc above) so AppDelegate's existing
         // call site needs no change at all — tests that need a private
         // `UserDefaults` suite pass these in explicitly instead.
         learnedWordsStore: LearnedWordsStore = LearnedWordsStore(),
         personalFrequencyStore: PersonalFrequencyStore = PersonalFrequencyStore(),
         feedbackTracker: CorrectionFeedbackTracker = CorrectionFeedbackTracker(),
         gameMode: GameModeState = .shared) {
        self.languageDetector = languageDetector
        self.secureInputDetector = secureInputDetector
        self.textReplacer = textReplacer
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.yoficatorService = yoficatorService
        self.switchUndoManager = switchUndoManager
        self.perAppLayoutService = perAppLayoutService
        self.instantCorrectionAnalyzer = instantCorrectionAnalyzer
        self.snippetService = snippetService
        self.learnedWordsStore = learnedWordsStore
        self.personalFreqStore = personalFrequencyStore
        self.feedbackTracker = feedbackTracker
        self.gameMode = gameMode
        self.activeAppBundleID = CommandLine.arguments.contains("--test")
            ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutDidChange(_:)),
            name: .layoutChanged, object: nil
        )

        // Mechanism A/C wiring (learning_spec.md): `isEnabled` mirrors
        // `Preferences.isLearningEnabled` at construction time — no UI
        // toggle exists yet (wave 3), so no live-observer is needed. Both
        // stores already no-op every mutation/query while disabled, and
        // `LanguageDetector.detect()`'s learned branch degrades to
        // no-op on an empty union, so this one assignment is the ONLY
        // gate the boundary path needs.
        self.learnedWordsStore.isEnabled = prefsService.isLearningEnabled
        self.personalFreqStore.isEnabled = prefsService.isLearningEnabled
        languageDetector.learnedWordsProvider = { [weak self] lang in
            guard let self else { return [] }
            let learned = self.learnedWordsStore.activeKeys(lang: lang)
            // Bug fix (bugfixes-diag-20260831.md Bug C): this closure is
            // called twice per word, synchronously in the CGEventTap
            // callback. `autoLearned` is snapshotted ONCE (was: `isAutoLearned`
            // per candidate — N `UserDefaults.dictionary(forKey:)` reads,
            // ~0.67ms/word at 142 keys, ~7.2ms at cap 2000, linear). Semantics
            // are identical — same dictionary, read once instead of per key.
            // `promotedNonDictionaryKeys` (not `promotedKeys`) also shrinks
            // the candidate set itself (142 → ~7 measured): a dictionary
            // entry's boundary-path score is already
            // `max(dictionaryScore, 80+min(20,len*2))` == `dictionaryScore`
            // when `inDictionary` is already true, so excluding
            // already-dictionary entries here is a provable no-op on
            // `detect()`'s outcome.
            let autoLearned = self.exceptionsService.autoLearned
            let personal = self.personalFreqStore.promotedNonDictionaryKeys(lang: lang)
                .filter { autoLearned[$0.lowercased()] == nil }
            return learned.union(personal)
        }

        // Same construction pattern as `AppDelegate.startHealthPolling`
        // (non-auto-scheduled `Timer` + explicit `.common`-mode add) rather
        // than `Timer.scheduledTimer` — avoids double-registering it on the
        // default run loop mode as well.
        let flushTimer = Timer(timeInterval: learningFlushInterval, repeats: true) { [weak self] _ in
            self?.flushLearning()
        }
        RunLoop.main.add(flushTimer, forMode: .common)
        learningFlushTimer = flushTimer
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        learningFlushTimer?.invalidate()
    }

    /// Persists Mechanism A/C's in-memory mutations — never called from the
    /// CGEventTap callback (both stores' own `flush` docs: no disk I/O on
    /// the hot path). Called by the ~30s timer above and, per
    /// `learning_spec.md`, `applicationWillTerminate` (`AppDelegate`).
    func flushLearning() {
        let now = Date()
        learnedWordsStore.flush(now: now)
        personalFreqStore.flush(now: now)
    }

    /// Wave-3 live toggle for `Preferences.isLearningEnabled`. Recording and
    /// the instant-path application already re-check `prefsService.isLearningEnabled`
    /// live at every call site (see `learnedActiveSet`,
    /// `handleDoubleShiftClassification`, `recordPersonalFrequencyBump`), so
    /// flipping the preference alone already mutes those. The one gap: the
    /// boundary path's `languageDetector.learnedWordsProvider` closure reads
    /// `store.activeKeys`/`promotedKeys` directly with no independent
    /// preference check of its own — those depend solely on each store's
    /// `isEnabled`, which the constructor only ever set once. Call this from
    /// wherever the UI toggle writes `prefsService.isLearningEnabled` so a
    /// promoted learned/personal word stops firing on the boundary path
    /// immediately, without an app restart.
    func setLearningEnabled(_ enabled: Bool) {
        learnedWordsStore.isEnabled = enabled
        personalFreqStore.isEnabled = enabled
    }

    @objc private func appDidActivate(_ notification: Notification) {
        if !CommandLine.arguments.contains("--test") {
            activeAppBundleID = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.bundleIdentifier
        }
        invalidateEditingContext(reason: "app-activated")
    }

    @objc private func layoutDidChange(_ notification: Notification) {
        // A layout switch WE triggered (mid-correction, Double Shift, Undo)
        // must not wipe buffered word context — the distributed notification
        // can arrive 2-40ms after we already resumed, racing our own
        // completion handlers (RC-3). A manual/bot-driven switch still resets
        // context exactly as before (v0.2.0 feature).
        let selfInitiated = (notification.userInfo?[InputSourceManager.selfInitiatedKey] as? Bool) ?? false
        guard !selfInitiated else { return }
        logContextWipe("layout-changed-externally")
        buffer.clear()
        pendingLeadingSymbols.removeAll()
        runKeystrokes.removeAll()
        wordAutorepeatCount = 0
        lastCompletedWord = nil
        instantCorrectionGate.reset()
        sentenceStartTracker.reset()
        languageDetector.resetContext()
        // Mechanism B reset point 2/7: external layout change.
        feedbackTracker.reset()
    }

    func start() {
        guard eventTap == nil else { return }
        guard permissionsService.hasAllPermissions else {
            health = .missingPermissions
            return
        }
        health = .starting

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        )

        guard let tap = eventTap else {
            NSLog("[KeyboardMonitor] Failed to create event tap")
            DebugLog.shared.log("KM", "ERROR: failed to create CGEventTap (check permissions)")
            health = .unavailable
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.invalidateEditingContext(reason: "mouse-click")
                }
            }
        }
        health = secureInputDetector.isSecureInput ? .secureInput : .running
        NSLog("[KeyboardMonitor] Started")
        DebugLog.shared.log("KM", "event tap started")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        isRunning = false
        health = .stopped
    }

    /// Polling entry point used by AppDelegate. It makes permission grants and
    /// event-tap recovery take effect without requiring an application restart.
    func refreshHealth() {
        guard permissionsService.hasAllPermissions else {
            if eventTap != nil { stop() }
            health = .missingPermissions
            return
        }
        guard let tap = eventTap else {
            start()
            return
        }
        if !CFMachPortIsValid(tap) {
            DebugLog.shared.log("KM", "event tap invalidated — restarting")
            stop()
            start()
            return
        }
        health = secureInputDetector.isSecureInput ? .secureInput : .running
    }

    // MARK: - Event Handling

    /// Internal (not fileprivate) so the headless test harness in
    /// TestRunner.swift can exercise the exact queue/skip contract directly.
    func queueIfReplacementActive(_ event: CGEvent) -> Bool {
        guard isPaused, !SyntheticEventMarker.shouldBypass(event) else { return false }
        // Modifier transitions (Shift/Cmd/Option/CapsLock) are deliberately
        // NEVER queued for replay — root cause of the "avalanche" incident
        // (CLAUDE.md): a real Shift down/up captured here and replayed later,
        // all at once right as the pause ends, arrives at
        // `HotkeyManager.handleFlagsChanged` with squashed, non-human timing.
        // Its Shift-tap gesture detector times taps in real wall-clock terms
        // — fed a replayed burst it can register a false Double Shift, which
        // fires another correction, whose own pause queues the NEXT physical
        // shift transition, and so on. Each queued keyDown/keyUp already
        // carries its own flags snapshot (`QueuedUserEvent.flags`), so the
        // target app doesn't need a correctly-ordered flagsChanged replay to
        // render correctly — letting real modifier transitions pass through
        // live (unsuppressed, analyzed with their true timing) costs nothing
        // and removes the fuse.
        guard event.type != .flagsChanged else { return false }
        pendingUserEvents.enqueue(QueuedUserEvent(type: event.type, event: event))
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

    fileprivate func handlesShortcut(type: CGEventType, event: CGEvent) -> Bool {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged && keycode == 57 {
            return prefsService.isCapsLockSwitchEnabled && !hotkeysBlocked()
        }
        guard type == .keyDown else { return false }
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

    /// Internal (not fileprivate) so the headless integration-test harness in
    /// TestRunner.swift can feed synthetic CGEvents directly — same code path
    /// the real CGEventTap callback uses, minus the tap plumbing itself.
    func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
            return
        }

        // Generated events carry a process-local marker. Unlike the old 300ms
        // cooldown, this filters only our own synthetic keystrokes (backspace/
        // retype) — replayed real keystrokes route as `.replayedUser` and are
        // analyzed exactly like live typing (RC-2: a replayed space must still
        // clear the buffer at a word boundary instead of bypassing analysis).
        if SyntheticEventMarker.route(event) == .ours { return }

        // Proof of life for the avalanche circuit breaker: a genuinely
        // physical event (not one we replayed from the pause queue) resets
        // the "consecutive auto-fires with no human action" counter. Placed
        // before any branch that can fire a correction, so it always applies
        // regardless of which path below eventually runs.
        if !SyntheticEventMarker.isReplayedUserEvent(event) {
            avalancheGuard.registerPhysicalEvent()
        }

        if type == .flagsChanged {
            hotkeyManager?.handleFlagsChanged(event)
            return
        }

        guard type == .keyDown else { return }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
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
        perAppLayoutService.rememberCurrentLayout()

        // Secure fields are never buffered, including while auto-switch is off.
        if secureInputDetector.isSecureInput {
            buffer.clear()
            pendingLeadingSymbols.removeAll()
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            lastCompletedWord = nil
            autoLearnTracker.cancel()
            // Mechanism B reset point 3/7: secure input.
            feedbackTracker.reset()
            health = .secureInput
            DebugLog.shared.log("KM", "skip: secure input")
            return
        }
        if health != .running { health = .running }

        // Stale buffer eviction — user paused typing too long, old keys don't belong to current word
        let now = CFAbsoluteTimeGetCurrent()
        if (!buffer.isEmpty || !pendingLeadingSymbols.isEmpty || !runKeystrokes.isEmpty)
            && (now - lastKeyTime) > staleBufferTimeout {
            logContextWipe("stale-\(Int((now - lastKeyTime).rounded()))s")
            buffer.clear()
            pendingLeadingSymbols.removeAll()
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            // Mechanism B reset point 4/7: stale-buffer eviction (10s idle).
            feedbackTracker.reset()
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
            && LicenseService.shared.isEntitled
            && appProfile?.blockAutoSwitch != true
            && !gameActive

        if InputBuffer.isDeleteKey(keycode) {
            if !pendingLeadingSymbols.isEmpty || lastCompletedWord != nil {
                logContextWipe("backspace")
            }
            switchUndoManager.invalidate()
            buffer.removeLast()
            lastCompletedWord = nil
            // Conservative: we can't tell from here whether the deleted
            // character was a letter or one of the tracked leading symbols,
            // so drop the run entirely rather than risk an over/under
            // backspace count on a later correction.
            pendingLeadingSymbols.removeAll()
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            autoLearnTracker.registerDeletion()
            // Mechanism B reset point 5/7: backspace.
            feedbackTracker.reset()
            // Bug fix (bugfixes-diag-20260831.md Bug B): the buffer isn't
            // necessarily empty after a backspace (only its LAST keystroke
            // was dropped), so the ordinary `buffer.isEmpty` → `startNewWord()`
            // path below never runs here — without this, an instant
            // correction earlier in the same word left `wasCorrected == true`
            // and silently gated the eventual word-boundary evaluation too
            // ("skip boundary correction: already instant-corrected" on a
            // word the owner had since edited by hand).
            instantCorrectionGate.reset()
            return
        }

        if InputBuffer.isWordBoundary(keycode) {
            // Captured before the reset right below — `handleWordBoundary`
            // needs "did THIS word have any held-key autorepeats" for the
            // game-mode prose-exit signal (spec §5), and by the time it runs
            // the counter has already been zeroed for the NEXT word.
            let wordHadHeldKeys = wordAutorepeatCount > 0
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            let correctable = InputBuffer.isCorrectableBoundary(keycode)
            handleWordBoundary(
                trailing: correctable ? " " : nil,
                canAutoCorrect: canAutoCorrect && correctable,
                keepForManualSwitch: correctable,
                triggerEvent: event,
                wordHadHeldKeys: wordHadHeldKeys
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
            // every keystroke after.
            if runKeystrokes.count == 32 { gameMode.note(.longRun) }
            // Field-debugging trace ("Подробный лог"): which keystroke stopped
            // growing the run. buf is pre-append for the letter path below.
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
            handleWordBoundary(
                trailing: punctChar,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true,
                triggerEvent: event
            )
            return
        }

        if InputBuffer.isLetterKey(keycode) {
            switchUndoManager.invalidate()
            autoLearnTracker.registerNonDeletion()
            if buffer.isEmpty {
                lastCompletedWord = nil
                lastAmbiguousKeyIndex = nil
                lastLoggedInstantSilence = nil
                instantCorrectionGate.startNewWord()
            }
            buffer.append(keycode, flags: flags)
            // Game mode `heldKeys` evidence (spec §5 table): counts letters
            // that landed with the OS autorepeat flag set — a game control
            // held down, not a human typing. Reset alongside `runKeystrokes`/
            // `buffer` at all 7 sites above.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { wordAutorepeatCount += 1 }
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
                return
            }
            let digit = languageDetector.inputSourceManager.trailingCharacter(
                keycode: keycode, flags: flags
            ) ?? ""
            handleWordBoundary(
                trailing: digit,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true,
                triggerEvent: event,
                triggerKeystroke: BufferedKeystroke(keycode: keycode, flags: flags)
            )
        } else {
            logContextWipe("navigation-key-\(keycode)")
            switchUndoManager.invalidate()
            autoLearnTracker.cancel()
            buffer.clear()
            pendingLeadingSymbols.removeAll()
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
            lastCompletedWord = nil
            // Mechanism B reset point 6/7: navigation keys.
            feedbackTracker.reset()
        }
    }

    private func handleWordBoundary(
        trailing: String?, canAutoCorrect: Bool, keepForManualSwitch: Bool, triggerEvent: CGEvent,
        triggerKeystroke: BufferedKeystroke? = nil, wordHadHeldKeys: Bool = false
    ) {
        let captured = buffer.currentWord()
        let capitalizeSentenceStart = captured.isEmpty ? false : sentenceStartTracker.consumeForWord()
        if captured.isEmpty { switchUndoManager.invalidate() }
        let retyped = languageDetector.lastConvertedWord(keystrokes: captured) ?? ""
        let learned = autoLearnTracker.confirmRetype(word: retyped, trailing: trailing)
        if let learned {
            exceptionsService.learnException(
                original: learned.original,
                corrected: learned.corrected
            )
            DebugLog.shared.log("AUTOLEARN", "exact retype confirmed")
        }

        let snippetStarted = learned == nil
            && prefsService.isSnippetExpansionEnabled
            && LicenseService.shared.isEntitled
            && pendingLeadingSymbols.isEmpty
            && !captured.isEmpty
            && expandSnippet(keystrokes: captured, trigger: trailing, triggerEvent: triggerEvent)

        let languageReplacementStarted = !snippetStarted && canAutoCorrect
            && learned == nil
            && !captured.isEmpty
            && processCurrentWord(
                trigger: trailing, triggerKeystroke: triggerKeystroke, triggerEvent: triggerEvent
            )
        let smartCaseStarted = !snippetStarted
            && !languageReplacementStarted
            && canAutoCorrect
            && learned == nil
            && prefsService.isSmartCaseEnabled
            && !captured.isEmpty
            && applySmartCase(
                keystrokes: captured, trigger: trailing, triggerEvent: triggerEvent,
                capitalizeSentenceStart: capitalizeSentenceStart
            )
        let replacementStarted = snippetStarted || languageReplacementStarted || smartCaseStarted
        // Empty boundaries can follow punctuation ("Hello." then Space). They
        // must not clear the sentence-start intent before the next word arrives.
        if !captured.isEmpty { sentenceStartTracker.observeBoundary(trailing) }

        if replacementStarted {
            lastCompletedWord = nil
        } else if keepForManualSwitch, !captured.isEmpty, let trailing,
                  let typedLayout = languageDetector.inputSourceManager.currentLayout {
            // Captured NOW, right as the word completes — this IS the layout
            // it was typed on (any layout change mid-word would already have
            // cleared `buffer` via `layoutDidChange`). `pendingLeadingSymbols`
            // is read here, BEFORE it's cleared below.
            lastCompletedWord = (captured, trailing, typedLayout, pendingLeadingSymbols, triggerKeystroke)
        } else {
            lastCompletedWord = nil
        }

        // Game mode prose-exit signal (spec §5) — deliberately NOT folded
        // into `processCurrentWord`'s `.noSwitch` branch (where
        // `recordPersonalFrequencyBump` computes the same kind of
        // dictionary-ness check): that branch only runs when `canAutoCorrect`
        // is true, and game mode being ACTIVE is exactly what makes it false
        // (see `canAutoCorrect`'s `!gameActive`) — the one case this signal
        // exists to observe. So it's computed independently here, at the
        // real word boundary (space only, matching spec §5 "граница =
        // пробел"), gated behind `gameMode.isActiveForFrontmost()` (an
        // in-memory read, same cost class as the rest of this hot path) so
        // the extra dictionary lookup is only ever paid while a bundleID is
        // actually flagged GAME — `noteProseWord` itself is a no-op
        // otherwise, so skipping the check when not needed changes nothing
        // observable.
        if trailing == " ", !captured.isEmpty, gameMode.isActiveForFrontmost(),
           let ownLayout = languageDetector.inputSourceManager.currentLayout {
            let ownText = languageDetector.inputSourceManager.convertKeystrokes(captured, toLayout: ownLayout)
            let ownCore = LanguageDetector.core(of: ownText)?.lowercased() ?? ""
            let isWord = !ownCore.isEmpty
                && languageDetector.isDictionaryWord(ownCore, language: ownLayout.languageCode)
            gameMode.noteProseWord(isDictionaryWord: isWord, len: ownCore.count, hasHeldKeys: wordHadHeldKeys)
        }

        buffer.clear()
        pendingLeadingSymbols.removeAll()
    }

    @discardableResult
    private func expandSnippet(
        keystrokes: [BufferedKeystroke], trigger: String?, triggerEvent: CGEvent
    ) -> Bool {
        guard !isPaused, let trigger,
              let layout = languageDetector.inputSourceManager.currentLayout else { return false }
        let typed = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        guard let replacement = snippetService.replacement(for: typed), replacement != typed else {
            return false
        }

        isPaused = true
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
        textReplacer.replaceCurrentWord(
            length: keystrokes.count,
            replacement: replacement,
            targetLayout: layout,
            trailing: trigger,
            trailingAlreadyOnScreen: false
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.pendingUserEvents.discardFront()
                DebugLog.shared.log(
                    "SNIPPET",
                    "expanded triggerLen=\(typed.count) replacementLen=\(replacement.count)"
                )
            case .layoutSwitchFailed:
                DebugLog.shared.log("SNIPPET", "expansion aborted: layout verification failed")
            case .cancelled:
                DebugLog.shared.log("SNIPPET", "expansion cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    @discardableResult
    private func applySmartCase(
        keystrokes: [BufferedKeystroke], trigger: String?, triggerEvent: CGEvent,
        capitalizeSentenceStart: Bool
    ) -> Bool {
        guard !isPaused, let trigger,
              let layout = languageDetector.inputSourceManager.currentLayout else { return false }
        let typed = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        guard !exceptionsService.isWordExcepted(typed),
              let replacement = SmartCaseNormalizer.normalized(
                  typed, capitalizeSentenceStart: capitalizeSentenceStart
              ) else { return false }

        isPaused = true
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
        textReplacer.replaceCurrentWord(
            length: keystrokes.count,
            replacement: replacement,
            targetLayout: layout,
            trailing: trigger,
            trailingAlreadyOnScreen: false
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.pendingUserEvents.discardFront()
                DebugLog.shared.log(
                    "SMARTCASE", "normalized len=\(typed.count) sentenceStart=\(capitalizeSentenceStart)"
                )
            case .layoutSwitchFailed:
                DebugLog.shared.log("SMARTCASE", "normalization aborted: layout verification failed")
            case .cancelled:
                DebugLog.shared.log("SMARTCASE", "normalization cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    /// Verbose-only observability for why instant correction did NOT fire on
    /// the word currently being typed (field defect 21.08.2026: the log
    /// recorded every instant SUCCESS but nothing about a refusal, so "instant
    /// fires rarely" was undiagnosable from the log alone — every silent word
    /// looked identical from outside). `DebugLog` self-gates on "Подробный
    /// лог"; the de-dup here additionally caps it at one line per word rather
    /// than one per keystroke. Reasons below `minLength` are not logged —
    /// they mean the word simply hasn't reached the point of being eligible
    /// yet, not that something held it back.
    private func logInstantSilence(_ reason: InstantCorrectionAnalyzer.SilenceReason?, len: Int) {
        guard let reason, len >= InstantCorrectionAnalyzer.minLength else { return }
        guard lastLoggedInstantSilence != reason else { return }
        lastLoggedInstantSilence = reason
        DebugLog.shared.log("KM", "instant silent: gate=\(reason.rawValue) len=\(len)", level: .verbose)
    }

    /// Evaluate the word buffered so far for an instant (mid-word) correction.
    /// Unlike `processCurrentWord`, this runs on every buffered letter once the
    /// buffer reaches `InstantCorrectionAnalyzer.minLength` — no word boundary
    /// (space/punctuation) is required. On success the active input source is
    /// switched immediately so the rest of the word types correctly, and
    /// `InstantCorrectionGate` is marked so the eventual boundary handler does
    /// not attempt a second correction on the same word.
    private func tryInstantCorrection(triggerEvent: CGEvent) {
        guard !isPaused else { return }
        let keystrokes = buffer.currentWord()
        guard keystrokes.count >= InstantCorrectionAnalyzer.minLength else { return }
        guard let currentLayout = languageDetector.inputSourceManager.currentLayout else { return }
        let layouts = languageDetector.activeLayouts
        guard layouts.count >= 2, layouts.contains(where: { $0.id == currentLayout.id }) else { return }
        let otherLayouts = layouts.filter { $0.id != currentLayout.id }

        let evaluation = instantCorrectionAnalyzer.evaluate(
            keystrokes: keystrokes,
            currentLayout: currentLayout,
            otherLayouts: otherLayouts,
            convert: { [languageDetector] layout in
                languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
            },
            learnedActive: learnedActiveSet(for: otherLayouts)
        )
        guard let result = evaluation.result else {
            logInstantSilence(evaluation.silence, len: keystrokes.count)
            return
        }
        if result.wasLearned {
            DebugLog.shared.log(
                "KM", "learned: fired path=instant lang=\(result.layout.languageCode) len=\(result.correctedWord.count)"
            )
        }

        if exceptionsService.isWordExcepted(result.correctedWord) {
            DebugLog.shared.log("KM", "instant skip: word exception match")
            return
        }
        let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes)
        if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
            DebugLog.shared.log("KM", "instant skip: auto-learned exception")
            return
        }

        var correctedWord = result.correctedWord
        if prefsService.isYoficatorEnabled && result.layout.isRussian {
            if let yo = yoficatorService.yoficate(correctedWord) { correctedWord = yo }
        }

        guard canFireAutoCorrection(branch: "instant correction") else { return }

        isPaused = true
        avalancheGuard.recordFired()
        instantCorrectionGate.markCorrected()
        // Same leading-symbol fold-in as the boundary path (processCurrentWord):
        // a "$"/"#"/"@"/"/" typed right before this word is on screen in the
        // CURRENT (wrong) layout already — reconvert it together with the
        // word instead of leaving it stuck in whatever rendered it.
        let leadingSymbols = pendingLeadingSymbols
        let leadingOriginalText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: currentLayout)
        let leadingCorrectedText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: result.layout)
        let runReplacement = leadingCorrectedText + correctedWord
        // The triggering letter is already in `keystrokes` (appended by
        // handleEvent just before this call) but has NOT reached the app yet
        // — headInsert tap runs before delivery. Suppress it so it can never
        // race our own backspaces (RC-1): only `keystrokes.count - 1` letters
        // are actually on screen (plus any leading symbols, which WERE
        // delivered normally); `correctedWord` already accounts for the
        // suppressed one.
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
        let length = leadingSymbols.count + keystrokes.count - 1
        textReplacer.replaceCurrentWord(
            length: length,
            replacement: runReplacement,
            targetLayout: result.layout,
            trailing: nil,
            trailingAlreadyOnScreen: true
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.pendingUserEvents.discardFront()
                let original = originalWord ?? ""
                self.switchUndoManager.record(
                    originalKeycodes: leadingSymbols.map(\.keycode) + keystrokes.map(\.keycode),
                    originalWord: leadingOriginalText + original,
                    correctedWord: runReplacement,
                    trailing: nil,
                    originalLayoutID: currentLayout.id,
                    targetLayoutID: result.layout.id
                )
                if !original.isEmpty {
                    self.autoLearnTracker.recordCorrection(
                        original: original, corrected: correctedWord, trailing: nil
                    )
                }
                if self.prefsService.isLearningEnabled, !original.isEmpty {
                    // Mechanism B feed (learning_spec.md): `wasLearned`
                    // re-checked against the store here — `result.wasLearned`
                    // already tells us this directly for the instant path,
                    // matching the boundary path's "check store.isActive
                    // at the success site" contract.
                    self.feedbackTracker.recordAutoCorrection(
                        original: original, corrected: correctedWord,
                        targetLang: result.layout.languageCode, wasLearned: result.wasLearned, at: Date()
                    )
                }
                self.statsService.recordAutoSwitch()
                SoundService.shared.playCorrection(prefsService: self.prefsService)
                NotificationCenter.default.post(name: .statsUpdated, object: nil)
                DebugLog.shared.log(
                    "KM",
                    "instant correction: \(currentLayout.languageCode)→\(result.layout.languageCode)"
                        + " len=\(length) lead=\(leadingSymbols.count)"
                        // net = characters the screen gains or loses on balance:
                        // retyped − erased − the one keystroke we suppressed (it
                        // never reached the screen, so it is part of the payload
                        // without ever having been backspaced over). Anything but
                        // 0 means the text silently changed length.
                        + " net=\(runReplacement.count - length - 1)"
                )
            case .layoutSwitchFailed:
                self.instantCorrectionGate.reset()
                DebugLog.shared.log("KM", "instant correction aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "instant correction cancelled: editing context changed")
            }
            self.finishReplacement()
        }
    }

    /// Shared circuit-breaker gate for the two fully-automatic correction
    /// entry points (instant + word boundary) — NOT used by Double Shift,
    /// see `avalancheGuard`'s doc comment. Checks the post-replacement
    /// cooldown first (quiet — expected to routinely apply right after any
    /// correction while typing fast) and the avalanche counter second (logs
    /// loudly — tripping it is always an anomaly, never normal typing).
    private func canFireAutoCorrection(branch: String) -> Bool {
        guard CFAbsoluteTimeGetCurrent() >= autoCorrectionCooldownUntil else { return false }
        guard avalancheGuard.canFire else {
            DebugLog.shared.log(
                "KM",
                "ALARM: correction avalanche guard tripped"
                    + " (\(avalancheGuard.consecutiveWithoutPhysicalInput) auto-fires with no physical input)"
                    + " — suppressing \(branch)"
            )
            return false
        }
        return true
    }

    /// Every wipe of the typed-word model is logged when it actually discards
    /// something. Without this the model can silently fall behind the screen
    /// and the next correction backspaces the wrong number of characters —
    /// and the log gives no way to tell which of the wipe points did it (this
    /// cost us a whole diagnosis round on the "./compact" report: the buffer
    /// held 4 characters while 5+ were on screen, and nothing said why).
    private func logContextWipe(_ reason: String) {
        guard !buffer.isEmpty || !pendingLeadingSymbols.isEmpty
            || !runKeystrokes.isEmpty || lastCompletedWord != nil else { return }
        DebugLog.shared.log(
            "KM",
            "buffer wiped: reason=\(reason) len=\(buffer.currentWord().count)"
                + " lead=\(pendingLeadingSymbols.count) run=\(runKeystrokes.count)"
                + " history=\(lastCompletedWord == nil ? 0 : 1)"
        )
    }

    // MARK: - Learning on behavior patterns (Mechanisms A/B/C, learning_spec.md)

    /// Instant-path Mechanism A set — plain, lowercased words active across
    /// EVERY currently-active layout's language, unioned with Mechanism C's
    /// boundary-only status EXCLUDED here (spec: C never applies on the
    /// instant path). Cyrillic and Latin cores can never collide textually,
    /// so a flat cross-language union is safe (see `learnedWordsProvider`'s
    /// own union for the same reasoning on the boundary side).
    private func learnedActiveSet(for layouts: [KeyboardLayout]) -> Set<String> {
        guard prefsService.isLearningEnabled else { return [] }
        var result: Set<String> = []
        for layout in layouts { result.formUnion(learnedWordsStore.activeKeys(lang: layout.languageCode)) }
        return result
    }

    /// Mechanism A's write-time normalization (learning_spec.md "Механизм A
    /// → Запись"). Returns the plain lowercased core to hand to
    /// `LearnedWordsStore.recordManualFix`, or nil (verbose-logged with the
    /// exact reason) when the gesture must never be learned. Never logs the
    /// word itself — lengths/reasons only.
    private func normalizedLearnableCore(from text: String, lang: String, resynced: Bool) -> String? {
        guard prefsService.isLearningEnabled else {
            DebugLog.shared.log("KM", "learned: skipped reason=disabled", level: .verbose)
            return nil
        }
        guard !resynced else {
            DebugLog.shared.log("KM", "learned: skipped reason=resynced", level: .verbose)
            return nil
        }
        guard let core = LanguageDetector.core(of: text)?.lowercased(), !core.isEmpty,
              !LanguageDetector.isMixedScript(core) else {
            DebugLog.shared.log("KM", "learned: skipped reason=mixedRun", level: .verbose)
            return nil
        }
        // Below this, neither application path (instant minLength=4,
        // boundary len>=3) can EVER fire — pointless to occupy a cap slot.
        guard core.count >= 3 else {
            DebugLog.shared.log("KM", "learned: skipped reason=belowMinLen", level: .verbose)
            return nil
        }
        guard !LanguageDetector.isReservedForDisambiguation(core, language: lang) else {
            DebugLog.shared.log("KM", "learned: skipped reason=conflictPair", level: .verbose)
            return nil
        }
        return core
    }

    /// Single dispatch point for a Double Shift gesture that just succeeded
    /// — called from all SIX DS success sites (3 below in this file via
    /// `positiveRecord` non-nil; 3 more in `HotkeyManager` via
    /// `classifyDoubleShiftGesture`, always `positiveRecord: nil`). Mirrors
    /// learning_spec.md "Перед записью — classify: manualFix → запись;
    /// toggleOfManualFix → revokeRecord; revert → см. B-механизм."
    /// `word`/`sourceLang`/`targetLang` describe the gesture as
    /// `CorrectionFeedbackTracker.classifyDoubleShift` expects: `word` reads
    /// in `sourceLang` right now, about to become `targetLang`.
    private func handleDoubleShiftClassification(
        word: String, sourceLang: String, targetLang: String,
        positiveRecord: (core: String, originApp: String?)?, nonEligibleReason: String = "selection|clipboard|caret",
        at: Date
    ) {
        guard prefsService.isLearningEnabled else { return }

        // Revert-of-revert checked FIRST and independently: a fresh DS
        // heading back into the direction JUST annulled by a revert (≤15s)
        // means "actually, keep the correction" — lifts the exception the
        // revert created instead of falling through to `.manualFix` and
        // re-learning a pair that's about to be reverted right back.
        if feedbackTracker.classifyRevertOfRevert(word: word, targetLang: targetLang, at: at) {
            exceptionsService.removeAutoLearned(word)
            DebugLog.shared.log("KM", "revert-of-revert: exception lifted")
            return
        }

        switch feedbackTracker.classifyDoubleShift(word: word, sourceLang: sourceLang, targetLang: targetLang, at: at) {
        case .revertOfAutoCorrection(let original, let corrected, let wasLearned):
            exceptionsService.learnException(original: original, corrected: corrected)
            if wasLearned, let core = LanguageDetector.core(of: corrected)?.lowercased() {
                learnedWordsStore.unlearn(word: core, lang: sourceLang)
                personalFreqStore.unlearn(word: core, lang: sourceLang)
            }
            feedbackTracker.recordRevert(original: original, corrected: corrected, at: at)
            DebugLog.shared.log("KM", "revert → exception (wasLearned=\(wasLearned), via=ds)")

        case .toggleOfManualFix(let toggledWord, let lang):
            learnedWordsStore.revokeRecord(word: toggledWord, lang: lang)
            DebugLog.shared.log("KM", "toggle revoked lang=\(lang) len=\(toggledWord.count)")

        case .manualFix:
            guard let positiveRecord else {
                DebugLog.shared.log("KM", "learned: skipped reason=\(nonEligibleReason)", level: .verbose)
                return
            }
            let outcome = learnedWordsStore.recordManualFix(
                word: positiveRecord.core, lang: targetLang, originApp: positiveRecord.originApp, at: at
            )
            let count = learnedWordsStore.allEntries["\(targetLang):\(positiveRecord.core)"]?.count ?? 0
            // Always-on (not verbose): the ONE event that shows the learning
            // chain started at all — verbose is OFF in the field since 24.08,
            // and without this line a real user's first DS fix of a pair is
            // invisible until promotion.
            DebugLog.shared.log(
                "KM", "learned: recorded lang=\(targetLang) len=\(positiveRecord.core.count) count=\(count)"
            )
            if outcome == .promoted {
                DebugLog.shared.log("KM", "learned: promoted lang=\(targetLang) len=\(positiveRecord.core.count)")
                // Bug fix (bugfixes-diag-20260831.md Bug A): checks the OWN
                // reading (`word`, in `sourceLang`) — the actual gate
                // (`wordLevel(own)==0` on the instant path, `scoreWord`'s
                // own-side gates on the boundary path) is keyed on the SOURCE
                // side, not the just-recorded TARGET core.
                if let ownCore = LanguageDetector.core(of: word)?.lowercased(),
                   languageDetector.isDictionaryWord(ownCore, language: sourceLang) {
                    // Honest UX signal (learning_spec.md verbose section):
                    // recorded and promoted, but the OWN reading is itself a
                    // real word of its own language — `wordLevel(own)==0` on
                    // the instant path and `scoreWord`'s own-side gates on
                    // the boundary path structurally can never let this fire.
                    DebugLog.shared.log("KM", "learned: inapplicable lang=\(targetLang) len=\(positiveRecord.core.count)")
                }
            }
            feedbackTracker.recordManualConversion(word: positiveRecord.core, sourceLang: sourceLang, targetLang: targetLang, at: at)
        }
    }

    /// Mirrors `handleDoubleShiftClassification` for `HotkeyManager`'s three
    /// non-A-eligible DS paths (AX selection / clipboard selection / AX
    /// caret word) — called there via `keyboardMonitor?`. `word` is the text
    /// as it reads BEFORE this conversion (in `sourceLang`). Never records
    /// positively (`positiveRecord: nil`): selection/clipboard content must
    /// never reach `LearnedWordsStore` (learning_spec.md Mechanism A
    /// "Пути... в запись НЕ идут никогда"), but classify still runs so a
    /// genuine revert/toggle via these paths is recognized instead of
    /// silently leaving stale tracker state armed for a later, unrelated
    /// gesture.
    func classifyDoubleShiftGesture(word: String, sourceLang: String, targetLang: String, via: String = "selection|clipboard|caret") {
        handleDoubleShiftClassification(
            word: word, sourceLang: sourceLang, targetLang: targetLang,
            positiveRecord: nil, nonEligibleReason: via, at: Date()
        )
    }

    /// Mechanism C's passive bump (learning_spec.md "Механизм C") — called
    /// ONLY from `processCurrentWord`'s `.noSwitch` branch: the word crossed
    /// a boundary and `detect()` found no reason to correct it. Reached only
    /// when `canAutoCorrect` was already true at the call site (license,
    /// auto-switch, per-app profile all already clear — see
    /// `handleWordBoundary`), so this adds only the gates the spec names
    /// beyond that. Bumps the RAW typed core — before Yoficator/snippets/
    /// smart-case ever see it.
    private func recordPersonalFrequencyBump(keystrokes: [BufferedKeystroke], currentLayout: KeyboardLayout) {
        guard prefsService.isLearningEnabled, !secureInputDetector.isSecureInput else { return }
        let ownText = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: currentLayout)
        guard let ownCore = LanguageDetector.core(of: ownText)?.lowercased(),
              !LanguageDetector.isMixedScript(ownCore), ownCore.count >= 3 else { return }
        guard languageDetector.isCleanReading(ownCore, language: currentLayout.languageCode) else {
            DebugLog.shared.log("KM", "[C] skipped reason=junkOwn", level: .verbose)
            return
        }

        // Anti-#19 (learning_spec.md 🔒): a word whose PROJECTION onto the
        // other active layout is already dictionary-valid OR learned-active
        // must never be bumped — a refused gate is not confirmation the
        // owner meant the own-language reading ("сдуфк" stays un-bumped;
        // its projection "clear" is a dictionary word).
        if let otherLayout = languageDetector.activeLayouts.first(where: { $0.id != currentLayout.id }) {
            let otherText = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: otherLayout)
            if let otherCore = LanguageDetector.core(of: otherText)?.lowercased(),
               !LanguageDetector.isMixedScript(otherCore) {
                let isWord = languageDetector.isDictionaryWord(otherCore, language: otherLayout.languageCode)
                let isLearned = learnedWordsStore.isActive(word: otherCore, lang: otherLayout.languageCode)
                guard !isWord, !isLearned else {
                    DebugLog.shared.log("KM", "[C] skipped reason=projectionIsWord", level: .verbose)
                    return
                }
            }
        }

        let isDictWord = languageDetector.isDictionaryWord(ownCore, language: currentLayout.languageCode)
        let outcome = personalFreqStore.bump(
            word: ownCore, lang: currentLayout.languageCode, isDictionaryWord: isDictWord, at: Date()
        )
        let count = personalFreqStore.allEntries["\(currentLayout.languageCode):\(ownCore)"]?.count ?? 0
        DebugLog.shared.log(
            "KM", "[C] bump len=\(ownCore.count) lang=\(currentLayout.languageCode) count=\(count)", level: .verbose
        )
        if outcome == .promoted {
            DebugLog.shared.log("KM", "[C] promoted len=\(ownCore.count) lang=\(currentLayout.languageCode)")
        }
    }

    private func invalidateEditingContext(reason: String = "unspecified") {
        if isPaused {
            invalidateAfterReplacement = true
            textReplacer.cancelCurrentReplacement()
            return
        }
        logContextWipe(reason)
        buffer.clear()
        pendingLeadingSymbols.removeAll()
        runKeystrokes.removeAll()
        wordAutorepeatCount = 0
        lastCompletedWord = nil
        autoLearnTracker.cancel()
        switchUndoManager.invalidate()
        instantCorrectionGate.reset()
        sentenceStartTracker.reset()
        languageDetector.resetContext()
        // Mechanism B reset point 1/7 (learning_spec.md): covers every
        // reason routed through here — app-activated, mouse-click,
        // modifier-shortcut, paste-no-format, blocked-app-hotkey.
        feedbackTracker.reset()
    }

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
        let axWord = AXTextSelectionService.focusedElement()
            .flatMap { AXTextSelectionService.valueAndCaret($0) }
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
                self.pendingLeadingSymbols.removeAll()
                self.lastCompletedWord = nil
                // Mechanism A/B (learning_spec.md): "via run" IS one of the
                // three A-eligible sources. Deliberately limited to runs
                // containing a non-letter (this function's own contract) —
                // `normalizedLearnableCore` rejects most of them via its own
                // ">1 core / empty" guard, which is correct: a mixed run is
                // a gesture, not a confirmed word pair.
                let learnableCore = self.normalizedLearnableCore(
                    from: converted, lang: targetLayout.languageCode, resynced: resynced
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
        guard !isPaused, LicenseService.shared.isEntitled else { return false }
        if convertWholeRun() { return true }
        var keystrokes = buffer.currentWord()
        var trailing: String? = nil
        var trailingKeystroke: BufferedKeystroke? = nil
        // Layout-dependent symbol(s) typed right before this word (e.g. "/"
        // in "/exit", "$" in "$GRAF") — tracked separately from `keystrokes`
        // exactly like the boundary/instant-correction paths, and folded
        // into the SAME transaction below instead of being silently left
        // un-converted (CLAUDE.md ".yexit" bug: this path used to ignore
        // `pendingLeadingSymbols` entirely).
        var leadingSymbols = pendingLeadingSymbols
        var source = "buffer"
        // The word must be scored against the layout it was ACTUALLY typed
        // on, never "whatever is active right now": for a word still live in
        // `buffer` that IS the layout active right now (no drift possible —
        // any layout change clears the buffer), but for a word pulled from
        // `lastCompletedWord` history (no TTL) the active layout can easily
        // have drifted since typing — see CLAUDE.md "марже" bug.
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
                    from: correctedWord, lang: targetLayout.languageCode, resynced: wasResynced
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
            case .layoutSwitchFailed:
                DebugLog.shared.log("KM", "doubleShift aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "doubleShift cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    /// - Parameter trigger: the character the user just typed that caused us to
    ///                      consider the buffered word complete (space / `.` / `;`
    ///                      etc). It already landed in the text field, so the
    ///                      replacer must backspace over it and re-type it.
    ///                      Pass nil only if nothing was printed after the word.
    @discardableResult
    private func processCurrentWord(
        trigger: String?, triggerKeystroke: BufferedKeystroke? = nil, triggerEvent: CGEvent
    ) -> Bool {
        guard !isPaused else { return false }
        if instantCorrectionGate.consumeIfCorrected() {
            DebugLog.shared.log("KM", "skip boundary correction: already instant-corrected")
            return false
        }
        let keystrokes = buffer.currentWord()
        // Short words are allowed, but ONLY when nothing precedes them on the
        // line. The floor used to be 3 letters, which meant the single-letter
        // Russian words — и, в, с, к, я, а, о, у — could never be fixed
        // automatically at all (owner typed "b", pressed space, nothing
        // happened). Two guards make one letter safe rather than reckless:
        //
        //  - a leading symbol blocks it outright. "rm -f" would otherwise
        //    become "rm -а", because "а" IS a Russian word and would win the
        //    scoring fairly. Command-line flags are the single most common
        //    place a lone letter appears next to a symbol.
        //  - `detect` already refuses any candidate that isn't in the
        //    dictionary, so "b" only moves because "и" is a real word, while
        //    "cd x" stays put ("ч" is not).
        let shortWordFloor = pendingLeadingSymbols.isEmpty ? 1 : 3
        guard keystrokes.count >= shortWordFloor else {
            DebugLog.shared.log("KM", "word too short (len=\(keystrokes.count))", level: .verbose)
            return false
        }

        // Sanity cap (gamemode-spec-20260831.md §4): same 20-keystroke limit
        // as the instant path's own `InstantCorrectionAnalyzer.maxLength`,
        // enforced independently here because the boundary path never calls
        // `evaluate()`. Catastrophic runs (a junk-override false switch
        // backspacing/retyping 30 characters into a game) never even reach
        // `detect()`. Double Shift is NOT capped (explicit gesture — see the
        // constant's own doc comment).
        guard pendingLeadingSymbols.count + keystrokes.count <= InstantCorrectionAnalyzer.maxLength else {
            DebugLog.shared.log(
                "KM", "word too long (len=\(pendingLeadingSymbols.count + keystrokes.count))", level: .verbose
            )
            return false
        }

        // Game mode gate (spec §5): ≥3 held-key autorepeats in this word —
        // same threshold and evidence as the instant path's own gate.
        if wordAutorepeatCount >= 3 {
            gameMode.note(.heldKeys)
            DebugLog.shared.log(
                "KM", "boundary skip: held keys (autorepeat=\(wordAutorepeatCount))", level: .verbose
            )
            return false
        }

        let result = languageDetector.detect(keystrokes: keystrokes)
        let currentLang = languageDetector.inputSourceManager.currentLayout?.languageCode ?? "?"

        switch result {
        case .noSwitch:
            DebugLog.shared.log("KM", "detect: noSwitch len=\(keystrokes.count) cur=\(currentLang)", level: .verbose)
            // Mechanism C's passive bump (learning_spec.md): the word
            // crossed a boundary with no correction — before Yoficator ever
            // touches it (bumps the RAW typed core).
            if let ownLayout = languageDetector.inputSourceManager.currentLayout {
                recordPersonalFrequencyBump(keystrokes: keystrokes, currentLayout: ownLayout)
            }
            if prefsService.isYoficatorEnabled {
                return applyYoficator(keystrokes: keystrokes, trigger: trigger)
            }
            return false

        case .switchTo(let layout, var correctedWord):
            if exceptionsService.isWordExcepted(correctedWord) {
                DebugLog.shared.log("KM", "skip: word exception match")
                return false
            }
            let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes)
            if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
                DebugLog.shared.log("KM", "skip: auto-learned exception")
                return false
            }

            // Mechanism A boundary observability (learning_spec.md):
            // `detect()` never propagates WHY a candidate won (that's the
            // whole point — the learned branch widens `inDictionary`/`score`
            // in place), so whether THIS fire came from a learned entry is
            // re-derived here the same way `undoLastCorrection`'s "разучивание"
            // note prescribes: check `store.isActive` on the result.
            let wasLearnedBoundary = learnedWordsStore.isActive(
                word: correctedWord.lowercased(), lang: layout.languageCode
            )
            if wasLearnedBoundary {
                DebugLog.shared.log(
                    "KM", "learned: fired path=boundary lang=\(layout.languageCode) len=\(correctedWord.count)"
                )
            }

            if prefsService.isYoficatorEnabled && layout.isRussian {
                if let yo = yoficatorService.yoficate(correctedWord) { correctedWord = yo }
            }

            guard let sourceLayout = languageDetector.inputSourceManager.currentLayout else {
                return false
            }

            // The trigger that closed this word (e.g. Shift+kc44) renders a
            // DIFFERENT printed character per layout — '?' in QWERTY, ',' in
            // ЙЦУКЕН; Shift+kc26 — '&' in QWERTY, '?' in ЙЦУКЕН (same
            // physical key, different symbol). `trigger` was rendered on the
            // SOURCE layout (before this switch); re-render it for the
            // TARGET layout the word is about to land in, so the retyped
            // payload prints the right symbol — "Да" + Shift+kc44 in en
            // becomes "Да," not "Да?".
            let retypedTrigger = triggerKeystroke.flatMap {
                languageDetector.inputSourceManager.characterForKeycode(
                    $0.keycode, layout: layout, flags: $0.flags
                )
            } ?? trigger

            // Layout-dependent symbols typed right before this word (e.g. "$"
            // in "$GRAF", "/" in "/model") were structurally unreachable for
            // correction before — fold them into the SAME backspace+retype
            // transaction so they're rendered in the TARGET layout too,
            // instead of being left in whatever (possibly wrong) layout
            // rendered them originally. The letter-only `keystrokes` above are
            // what `detect()` scored — this never changes that calibration.
            let leadingSymbols = pendingLeadingSymbols
            let runLength = leadingSymbols.count + keystrokes.count
            let leadingOriginalText = leadingSymbols.isEmpty ? ""
                : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: sourceLayout)
            let leadingCorrectedText = leadingSymbols.isEmpty ? ""
                : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: layout)
            let runReplacement = leadingCorrectedText + correctedWord

            guard canFireAutoCorrection(branch: "boundary correction") else { return false }

            // The word itself is already on screen (typed letter-by-letter
            // normally), but the trigger that just completed it (space/
            // punctuation) hasn't been delivered yet — headInsert tap runs
            // before delivery. Suppress it so it can never race our own
            // backspaces (RC-1); it's retyped as part of the payload instead.
            isPaused = true
            avalancheGuard.recordFired()
            suppressCurrentEvent = true
            pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
            textReplacer.replaceCurrentWord(
                length: runLength,
                replacement: runReplacement,
                targetLayout: layout,
                trailing: retypedTrigger,
                trailingAlreadyOnScreen: false
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.pendingUserEvents.discardFront()
                    let original = originalWord ?? ""
                    self.switchUndoManager.record(
                        originalKeycodes: leadingSymbols.map(\.keycode) + keystrokes.map(\.keycode),
                        originalWord: leadingOriginalText + original,
                        correctedWord: runReplacement,
                        trailing: retypedTrigger,
                        originalLayoutID: sourceLayout.id,
                        targetLayoutID: layout.id
                    )
                    if !original.isEmpty {
                        self.autoLearnTracker.recordCorrection(
                            original: original,
                            corrected: correctedWord,
                            trailing: trigger
                        )
                    }
                    if self.prefsService.isLearningEnabled, !original.isEmpty {
                        self.feedbackTracker.recordAutoCorrection(
                            original: original, corrected: correctedWord,
                            targetLang: layout.languageCode, wasLearned: wasLearnedBoundary, at: Date()
                        )
                    }
                    self.statsService.recordAutoSwitch()
                    SoundService.shared.playCorrection(prefsService: self.prefsService)
                    NotificationCenter.default.post(name: .statsUpdated, object: nil)
                    DebugLog.shared.log(
                        "KM",
                        "correction: \(sourceLayout.languageCode)→\(layout.languageCode)"
                            + " len=\(runLength) lead=\(leadingSymbols.count) trig=\(retypedTrigger ?? "∅")"
                            // See the instant path: retyped − erased − the
                            // suppressed trigger. Must be 0; any other value is
                            // exactly how many characters the text silently
                            // gained or lost. Bare counts, never content — so a
                            // report like "a letter went missing" is one glance
                            // to diagnose instead of a round of guesses.
                            + " net=\(runReplacement.count + (retypedTrigger?.count ?? 0) - runLength - 1)"
                    )
                case .layoutSwitchFailed:
                    // Layout switch failed → nothing was retyped, the word is
                    // still on screen in `sourceLayout` exactly as typed — so
                    // history keeps the ORIGINAL (source-rendered) `trigger`,
                    // not `retypedTrigger` (which was rendered for the target
                    // layout that never actually took effect).
                    if let trigger {
                        self.lastCompletedWord = (keystrokes, trigger, sourceLayout, leadingSymbols, triggerKeystroke)
                    }
                    DebugLog.shared.log("KM", "correction aborted: layout switch verification failed")
                case .cancelled:
                    DebugLog.shared.log("KM", "correction cancelled: editing context changed")
                }
                self.finishReplacement()
            }
            return true
        }
    }

    @discardableResult
    private func applyYoficator(keystrokes: [BufferedKeystroke], trigger: String?) -> Bool {
        guard let currentLayout = languageDetector.currentRussianLayout() else { return false }
        let word = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: currentLayout)
        if let yo = yoficatorService.yoficate(word), yo != word {
            isPaused = true
            textReplacer.replaceCurrentWord(
                length: keystrokes.count,
                replacement: yo,
                targetLayout: currentLayout,
                trailing: trigger,
                trailingAlreadyOnScreen: true
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.switchUndoManager.record(
                        originalKeycodes: keystrokes.map(\.keycode),
                        originalWord: word,
                        correctedWord: yo,
                        trailing: trigger,
                        originalLayoutID: currentLayout.id,
                        targetLayoutID: currentLayout.id
                    )
                    self.statsService.recordTypoFix()
                    NotificationCenter.default.post(name: .statsUpdated, object: nil)
                case .layoutSwitchFailed:
                    DebugLog.shared.log("KM", "yoficator aborted: layout switch verification failed")
                case .cancelled:
                    DebugLog.shared.log("KM", "yoficator cancelled: editing context changed")
                }
                self.finishReplacement()
            }
            return true
        }
        return false
    }

    @discardableResult
    func undoLastCorrection() -> Bool {
        guard !isPaused else { return false }
        guard let correction = switchUndoManager.lastCorrection else { return false }
        guard let originalLayout = languageDetector.inputSourceManager.layout(
            withID: correction.originalLayoutID
        ) else { return false }
        _ = switchUndoManager.consume()
        // Mechanism B reset point 7/7 (learning_spec.md).
        feedbackTracker.reset()

        isPaused = true
        textReplacer.replaceCurrentWord(
            length: correction.correctedWord.count,
            replacement: correction.originalWord,
            targetLayout: originalLayout,
            trailing: correction.trailing,
            trailingAlreadyOnScreen: true
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.buffer.clear()
                self.lastCompletedWord = nil
                self.autoLearnTracker.cancel()
                // Mechanism B main path (learning_spec.md "Главный путь
                // отката — undo"): `switchUndoManager.lastCorrection` KNOWS
                // original/corrected/layout — no heuristic needed. Always
                // learns the exception; additionally unlearns from BOTH
                // stores when the corrected word carries an active
                // learned/promoted record (checked here, since
                // `wasLearnedFired` is never threaded through `detect()`).
                if self.prefsService.isLearningEnabled {
                    let targetLayoutForUndo = self.languageDetector.inputSourceManager.layout(
                        withID: correction.targetLayoutID
                    )
                    var wasLearned = false
                    if let core = LanguageDetector.core(of: correction.correctedWord)?.lowercased(),
                       let lang = targetLayoutForUndo?.languageCode {
                        wasLearned = self.learnedWordsStore.isActive(word: core, lang: lang)
                            || self.personalFreqStore.isPromoted(word: core, lang: lang)
                        if wasLearned {
                            self.learnedWordsStore.unlearn(word: core, lang: lang)
                            self.personalFreqStore.unlearn(word: core, lang: lang)
                        }
                    }
                    self.exceptionsService.learnException(
                        original: correction.originalWord, corrected: correction.correctedWord
                    )
                    self.feedbackTracker.recordRevert(
                        original: correction.originalWord, corrected: correction.correctedWord, at: Date()
                    )
                    DebugLog.shared.log("KM", "revert → exception (wasLearned=\(wasLearned), via=undo)")
                }
                SoundService.shared.playSwitch(targetLanguageCode: originalLayout.languageCode, prefsService: self.prefsService)
                DebugLog.shared.log("KM", "undo applied with trailing preserved")
            case .layoutSwitchFailed:
                self.switchUndoManager.record(
                    originalKeycodes: correction.originalKeycodes,
                    originalWord: correction.originalWord,
                    correctedWord: correction.correctedWord,
                    trailing: correction.trailing,
                    originalLayoutID: correction.originalLayoutID,
                    targetLayoutID: correction.targetLayoutID
                )
                DebugLog.shared.log("KM", "undo aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "undo cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    private func finishReplacement() {
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
        for queued in pendingUserEvents.drain() {
            guard let event = queued.makeEvent() else {
                // No fallback exists if CGEvent construction itself fails
                // system-wide — but silently `continue`-ing here used to
                // drop the character with zero trace. Logging at least turns
                // an invisible loss into a diagnosable one (task: "терять
                // символы нельзя" — this is the honest floor when recovery
                // genuinely isn't possible).
                DebugLog.shared.log("KM", "WARNING: dropped a queued keystroke — CGEvent construction failed")
                continue
            }
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
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
        return screenWord.hasSuffix(modelWord)
    }

    // MARK: - Callback-duration watchdog

    /// Pure threshold decision — extracted so it's directly unit-testable
    /// without needing to actually stall the real CGEventTap callback (a
    /// timing test here would be exactly the kind of flaky test the
    /// structural-guard tests elsewhere in this file are trying to avoid).
    static func shouldWarnSlowCallback(_ seconds: CFAbsoluteTime, threshold: CFAbsoluteTime) -> Bool {
        seconds > threshold
    }

    /// Called by `eventTapCallback` right after every dispatch. Not private
    /// so `KeyboardMonitorHarness` can exercise the same contract
    /// deterministically. Logs which event type ran and whether it ended up
    /// suppressing/replacing anything — the closest to "which branch" we can
    /// get without instrumenting every internal branch individually.
    func recordCallbackDuration(
        _ seconds: CFAbsoluteTime, type: CGEventType, suppressed: Bool
    ) {
        guard Self.shouldWarnSlowCallback(seconds, threshold: callbackWarnThreshold) else { return }
        let ms = Int((seconds * 1000).rounded())
        DebugLog.shared.log(
            "KM",
            "WARNING: slow tap callback \(ms)ms type=\(type.rawValue) suppressed=\(suppressed)"
                + " — regression risk (macOS disables the tap on repeated timeouts)"
        )
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let isDisableNotification = type == .tapDisabledByTimeout
        || type == .tapDisabledByUserInput
    if !isDisableNotification && SyntheticEventMarker.route(event) == .ours {
        return Unmanaged.passUnretained(event)
    }
    if !isDisableNotification && monitor.queueIfReplacementActive(event) { return nil }
    let callbackStart = CFAbsoluteTimeGetCurrent()
    let suppressHandledShortcut = monitor.handlesShortcut(type: type, event: event)
    monitor.handleEvent(proxy, type: type, event: event)
    let suppressTrigger = monitor.consumeSuppressCurrentEvent()
    let suppressed = suppressHandledShortcut || suppressTrigger
    monitor.recordCallbackDuration(CFAbsoluteTimeGetCurrent() - callbackStart, type: type, suppressed: suppressed)
    return suppressed ? nil : Unmanaged.passUnretained(event)
}
