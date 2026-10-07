import Foundation
import CoreGraphics
import AppKit
import Darwin

final class KeyboardMonitor {
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    let buffer = InputBuffer()
    let languageDetector: LanguageDetector
    let textReplacer: TextReplacing
    let statsService: StatisticsService
    let prefsService: PreferencesService
    let exceptionsService: ExceptionsService
    private let yoficatorService: YoficatorService
    let switchUndoManager: SwitchUndoManager
    let perAppLayoutService: PerAppLayoutService
    private let instantCorrectionAnalyzer: InstantCorrectionAnalyzer
    private let snippetService: SnippetService
    var sentenceStartTracker = SentenceStartTracker()
    var instantCorrectionGate = InstantCorrectionGate()
    let secureInputDetector: SecureInputDetector
    private let permissionsService = PermissionsService()
    var activeAppBundleID: String?
    var hotkeyManager: HotkeyManager?
    private(set) var isRunning = false
    var health: EventTapHealth = .stopped {
        didSet {
            guard health != oldValue else { return }
            NotificationCenter.default.post(name: .eventTapHealthChanged, object: self)
        }
    }
    var isPaused = false
    var pendingUserEvents = PendingUserEventQueue<KeyEventSnapshot>()
    var isDrainingPendingEvents = false
    var invalidateAfterReplacement = false

    /// Side effect for DELIVERING a queued keystroke to the app once a paused
    /// replacement finishes — delivery only, never analysis. Production posts
    /// a real CGEvent at `.cgAnnotatedSessionEventTap`, which is DOWNSTREAM of
    /// our own `.cgSessionEventTap`: the posted event never re-enters
    /// `eventTapCallback`/`handle(_:)`. (This comment used to say the tap
    /// "sees it again" — it does not, and a replayed letter silently stayed
    /// out of `buffer`/`runKeystrokes`: the field log showed the next word
    /// starting at `run=1 buf=0` without its first letter, and a later
    /// correction of that word erased one character too few, leaving a stray
    /// old-layout letter in front.) Analysis therefore happens in
    /// `drainPendingUserEvents`, which mirrors the tap callback before it
    /// calls this. The headless test harness overrides this to render the
    /// key on its fake screen — and must not call `handle` itself.
    /// `drainPendingUserEvents` is the only caller.
    var replaySink: (KeyEventSnapshot) -> Void = { snapshot in
        guard let event = snapshot.makeEvent() else {
            // No fallback exists if CGEvent construction itself fails
            // system-wide — but silently dropping it here used to lose the
            // character with zero trace. Logging at least turns an invisible
            // loss into a diagnosable one.
            DebugLog.shared.log("KM", "WARNING: dropped a queued keystroke — CGEvent construction failed")
            return
        }
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Source of "the real text and caret position under the focused field",
    /// read by Double Shift's run-resync (`convertWholeRun`) before falling
    /// through to the scored path. Production asks the real Accessibility
    /// API; the headless test harness has no focused element to read and
    /// overrides this to `{ nil }` (same as AX silently returning nothing).
    var focusedTextProvider: () -> (text: String, caret: Int)? = {
        AXTextSelectionService.focusedElement().flatMap { AXTextSelectionService.valueAndCaret($0) }
    }

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
    var runKeystrokes: [BufferedKeystroke] = []

    /// Set by `processCurrentWord` right before a language replacement
    /// starts, to the trigger symbol as it will actually render in the
    /// TARGET layout (e.g. EN "?" typed for RU "," renders as ","). Cleared
    /// before each `processCurrentWord` call in `handleWordBoundary` so a
    /// boundary where no replacement starts never reads a stale value —
    /// smart case must judge the sentence end by what lands on screen.
    private var lastRetypedTrigger: String?

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
    var pendingRunResync: Int?

    /// The screen word measured alongside `pendingRunResync` above — needed
    /// separately because deciding whether to trust a LONGER measurement
    /// requires seeing the actual characters (does the screen word end with
    /// what we typed?), not just comparing two counts. Same lifecycle as
    /// `pendingRunResync`: set together, cleared together.
    var pendingRunResyncWord: String?

    /// Island feature (v0.11.0, docs/HISTORY.md "v0.11.0 (10.09.2026)"): a single foreign word
    /// just got corrected, but its own word boundary hasn't been reached yet
    /// (instant correction) or the boundary that just fired couldn't act
    /// immediately (queue non-empty / punctuation, not prose). `restoreIsland`
    /// is the only place that clears this, on every exit path.
    var pendingIslandRestore = false
    /// The language the pending island word was just corrected INTO — set
    /// alongside `pendingIslandRestore`. `restoreIsland` cannot re-derive
    /// this from `languageDetector.contextSlots` on its own: for an
    /// instant-corrected word the ring is never touched at all (see
    /// `LanguageDetector.detect`'s doc comment — instant correction goes
    /// through `InstantCorrectionAnalyzer.evaluate`, not `detect`), so there
    /// is nothing in the ring identifying which word this restore is for.
    var pendingIslandTarget: String?
    /// The (at most 2) ring slots immediately BEFORE the pending island word, captured when the
    /// island was ARMED (before any ring write for that word). `restoreIsland` reads this instead
    /// of re-deriving "the words before" from the live ring, which has moved on by then (deferred
    /// path) or carries the word's own slot (boundary / Double Shift). Cleared together with
    /// `pendingIslandTarget` at every site that clears it.
    var pendingIslandContext: [LanguageDetector.ContextSlot]?
    /// The word that ARMED the pending island has already ended (its boundary passed without
    /// running the restore). Armed `true` by a boundary-success / Double Shift-via-history
    /// deferral; `false` by instant arming and Double Shift via buffer (their word is still being
    /// typed); set `true` by `handleWordBoundary` when the deferred restore does not fire. A new
    /// word starting while this is set belongs to a LATER run → `cancelStalePendingIsland`.
    var pendingIslandOwnerEnded = false

    /// The island's "owner is already typing" gate: only a queued keyDown counts. The tap queues
    /// keyUps too, and a trigger's or letter's keyUp alone is not the next word being typed.
    var hasQueuedKeyDown: Bool {
        pendingUserEvents.contains { $0.type == .keyDown }
    }

    // Avalanche circuit breaker (see CorrectionAvalancheGuard) — applies only
    // to the two fully-automatic correction entry points (instant + word
    // boundary). Double Shift is intentionally NOT gated by either of these:
    // it fires only from an individually-timed physical Shift-tap gesture,
    // and rapid manual re-presses (toggle back and forth on the same word)
    // are an existing, tested feature with no artificial delay.
    // internal(set) so KeyboardMonitorHarness-based tests can observe that
    // the guard is actually wired into the real correction path (not just
    // exercise the pure struct in isolation).
    var avalancheGuard = CorrectionAvalancheGuard()
    var autoCorrectionCooldownUntil: CFAbsoluteTime = 0
    let autoCorrectionCooldownInterval: CFAbsoluteTime = 0.2

    // MARK: - Chorded comma (plan 013, step B)

    /// How long after a kc44 "." a Shift-down still counts as the chord's late Shift.
    /// Field max 105 ms; 0 negatives inside 250 ms in 24 h of typing — the bare-tap gate
    /// (Shift released with no key pressed while held) is the real discriminator, the window
    /// only bounds how stale a candidate may be.
    private let chordCommaWindow: CFAbsoluteTime = 0.120
    /// Longest Shift hold that still counts as the slipped-comma chord. Field 07.10: the
    /// late bare Shift was held 100–227 ms in all 20 cases; a longer bare hold right after
    /// a "." is a deliberate Shift, so the "." stays.
    private let chordCommaMaxHold: CFAbsoluteTime = 0.400

    /// A kc44 "." typed without Shift on a layout where Shift+kc44 is "," — the keyboard
    /// sometimes delivers the key a hair BEFORE its Shift (field: 20 of 206 commas, Shift
    /// 2-105 ms later, always released as a bare tap). `shiftDownAt` is set once a
    /// Shift-down inside the window marked it; the repair itself waits for that Shift's release.
    struct ChordCommaCandidate {
        let armedAt: CFAbsoluteTime
        let layoutID: String
        var shiftDownAt: CFAbsoluteTime?
    }
    var chordComma: ChordCommaCandidate?

    // MARK: - First-burst retype (plan 013, step C)

    /// A one-or-two letter burst whose last letter is at most this old when macOS reports an
    /// external layout change is treated as typed just before the flip. Field: the flip lands
    /// 25-32 ms after the first key (3 of 3 external changes in 24 h); 80 ms leaves margin without
    /// reaching ordinary typing rhythm (a second key, or any Shift, voids it anyway).
    private let firstBurstRetypeWindow: CFAbsoluteTime = 0.080

    /// Layout every letter currently in `buffer` was typed in, read from `currentLayout` at each
    /// append (set when the buffer was empty, `nil` as soon as one letter came from a different
    /// layout). Nothing else in the monitor remembers this: the live layout is read at use time
    /// and a notification can be 25+ ms late. Doubles as the duplicate-notification guard: a
    /// "change" to the layout the buffer was typed in changed nothing for that text.
    var bufferTypedLayoutID: String?

    /// True while the last keyDown/flagsChanged the tap saw was the append of a buffered letter
    /// (keyUps do not count). Answers "was the letter the very last event before the layout
    /// notification" — `lastKeyTime` then is that letter's arrival time.
    var lastEventWasLetter = false

    /// The per-document input-source switch this retype fixes happens when a just-activated app's
    /// field takes focus on the first keystroke (field: the buffered letter was the first keyDown
    /// after `app activated`, 1.8-2.8 s later). Only that shape is retyped: the letters must be the
    /// only keyDowns since the last activation, and the activation at most this old. A focus jump
    /// in the middle of typing is out of scope by design — the text check alone cannot tell the
    /// field it was typed into from another field that happens to end with the same letter.
    private let firstBurstActivationWindow: CFAbsoluteTime = 5.0
    private var lastActivationAt: CFAbsoluteTime = 0
    var keyDownsSinceActivation = 0

    /// Count of `.tapDisabledByTimeout` events seen this run — a live-log
    /// counter (task: "защита от повторения") so a regression shows up as a
    /// rising number, not just individual log lines a human has to notice.
    var tapTimeoutDisableCount = 0

    private let callbackWarnThreshold: CFAbsoluteTime = 0.015 // 15ms
    // Set synchronously while handling a keydown we've decided to suppress
    // (its trigger races with our own backspaces — RC-1). Consumed exactly
    // once by the event tap callback right after `handleEvent` returns.
    var suppressCurrentEvent = false

    var autoLearnTracker = AutoLearnTracker()

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
    let gameMode: GameModeState

    /// Autorepeat keystrokes seen in the run/word currently being buffered
    /// (spec §5 `heldKeys` evidence). Reset at every point that resets
    /// `runKeystrokes`/`buffer` (7 sites, see `runKeystrokes.removeAll()`).
    /// Hot-path: a plain increment on a value already read off the CGEvent —
    /// no UserDefaults/Bundle/NSWorkspace call.
    var wordAutorepeatCount = 0

    // Stale-buffer eviction: drop accumulated keys if user paused typing too long
    var lastKeyTime: CFAbsoluteTime = 0
    let staleBufferTimeout: CFAbsoluteTime = 10.0 // 10 sec idle → clear

    // Last completed word (for Double Shift fallback after space).
    // When user types "ghbdtn " and then hits Double Shift, the main buffer is
    // already empty — we pull keycodes from here instead.
    // `typedLayout` is the layout that was ACTUALLY active while these
    // keycodes were typed/produced — captured at the moment this tuple is
    // written, never re-derived from "whatever is active now" when Double
    // Shift is eventually pressed (this history has no TTL, so the active
    // layout can easily have drifted by then — see MarzheDoubleShiftRegressionTests).
    /// `languageDetector.ringWriteCount` right after the ring write that gave `lastCompletedWord`
    /// its slot; nil = the history word wrote none. The slot is the ring's last one only while the
    /// detector's counter still equals this — any later write moves it.
    /// Only read while `lastCompletedWord != nil`, so clearing the history needs no reset here.
    var lastCompletedWordSlotWrite: Int?
    var lastCompletedWord: (
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
    var pendingLeadingSymbols: [BufferedKeystroke] = []

    /// Digits typed with no letters yet ("5" in "Готово. 5 минут"): the
    /// sentence starts with the number, so smart case must not capitalize
    /// the word after it.
    var pendingLeadHasDigit: Bool {
        pendingLeadingSymbols.contains {
            InputBuffer.digitChar(keycode: $0.keycode, flags: $0.flags)?.first?.isNumber == true
        }
    }

    /// Position (1-based `buffer.count` right after it was appended) of the
    /// most recent alphabet-ambiguous key — a letter in one alphabet and
    /// punctuation in the other, see `InputBuffer.isAlphabetAmbiguous` — in
    /// the word currently being buffered. `nil` once no such key has been
    /// typed yet for this word. Recomputed every keystroke rather than
    /// latched for the whole word — see `ambiguousKeyRecent`.
    var lastAmbiguousKeyIndex: Int?

    /// De-dup key for `logInstantSilence` — the same silence reason is
    /// written at most once per word, right when it FIRST applies, instead
    /// of once per keystroke. Without this a 12-letter internal word would
    /// write the same `gate=ownIsWord` line 9 times, roughly doubling the
    /// log's write rate for zero extra signal. Reset alongside
    /// `lastAmbiguousKeyIndex` whenever a new word starts.
    var lastLoggedInstantSilence: InstantCorrectionAnalyzer.SilenceReason?

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
    var ambiguousKeyRecent: Bool {
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
        self.activeAppBundleID = TestRunMode.isActive
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

    // MARK: - Read-only snapshot for the opt-in updater's idle policy (0.11.0)

    /// Seconds since the last keystroke the tap saw (huge when nothing was
    /// typed since launch), whether game mode is active for the frontmost
    /// app, and whether a replacement transaction is in flight. Read on the
    /// main thread by the update service before it decides to install —
    /// never from inside the tap callback. Exposes existing private state
    /// only; nothing here changes behavior.
    var updateSafetySnapshot: (idleSeconds: TimeInterval, gameModeActive: Bool, replacing: Bool) {
        (
            idleSeconds: CFAbsoluteTimeGetCurrent() - lastKeyTime,
            gameModeActive: gameMode.isActiveForFrontmost(),
            replacing: isPaused
        )
    }

#if DEBUG
    /// Test seam: `activeAppBundleID` is nil under `TestRunMode`, so a terminal-only rule needs a way in.
    func setActiveAppBundleIDForTesting(_ id: String?) { activeAppBundleID = id }
#endif

    @objc func appDidActivate(_ notification: Notification) { // internal: the test harness drives it
        lastActivationAt = CFAbsoluteTimeGetCurrent()
        keyDownsSinceActivation = 0
        if !TestRunMode.isActive {
            activeAppBundleID = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.bundleIdentifier
        }
        // Verbose-only, logged on EVERY activation (not just when a buffer is
        // wiped): the 10.09.2026 field analysis could not attribute a single
        // correction or Double Shift to an app because nothing in the trace
        // named the frontmost bundle. A bundle id is metadata, never text.
        DebugLog.shared.log("KM", "app activated: app=\(activeAppBundleID ?? "?")", level: .verbose)
        invalidateEditingContext(reason: "app-activated")
    }

    @objc private func layoutDidChange(_ notification: Notification) {
        // A layout switch WE triggered (mid-correction, Double Shift, Undo)
        // must not wipe buffered word context — the distributed notification
        // can arrive 2-40ms after we already resumed, racing our own
        // completion handlers (RC-3). A manual/bot-driven switch still resets
        // context exactly as before (v0.2.0 feature).
        let selfInitiated = (notification.userInfo?[InputSourceManager.selfInitiatedKey] as? Bool) ?? false
        // Plan 013 B: a chord candidate belongs to ONE layout — any change, ours or not, voids it.
        chordComma = nil
        let newLayout = languageDetector.inputSourceManager.currentLayout
        guard !selfInitiated else {
            // Our own switch moved the layout away from where the buffered letters were typed.
            if bufferTypedLayoutID != newLayout?.id { bufferTypedLayoutID = nil }
            return
        }
        // Plan 013 C: a "change" to the layout the buffered letters were typed in is the
        // duplicate notification (or our own first-burst retype settling) — the text is already
        // in that layout, so there is nothing to retype and nothing to wipe.
        if !buffer.isEmpty, let id = newLayout?.id, bufferTypedLayoutID == id {
            DebugLog.shared.log("KM", "layout change ignored: buffer already typed in it", level: .verbose)
            return
        }
        if retypeFirstBurstIfEligible(newLayout: newLayout) { return }
        wipeContextAfterExternalLayoutChange()
    }

    private func wipeContextAfterExternalLayoutChange() {
        // Mechanism B reset point 2/7: external layout change.
        resetTypingContext(.externalLayoutChange)
    }

    /// The text before a UTF-16 caret offset (clamped to the string).
    private static func textBeforeCaret(_ text: String, caret: Int) -> String {
        let ns = text as NSString
        return ns.substring(to: max(0, min(caret, ns.length)))
    }

    /// Auto correction is allowed for the frontmost app right now: auto switch on, the app
    /// profile does not block it, no game mode, no secure input. Same conditions as
    /// `canAutoCorrect` in `handle` (which also needs the profile for other gates, so it keeps
    /// its own copy), plus secure input (which `handle` checks earlier, before buffering).
    private func autoCorrectionAllowedNow() -> Bool {
        let appProfile = activeAppBundleID.flatMap { exceptionsService.profile(for: $0) }
        return prefsService.isAutoSwitchEnabled
            && appProfile?.blockAutoSwitch != true
            && !gameMode.isActive(bundleID: activeAppBundleID)
            && !secureInputDetector.isSecureInput
    }

    /// macOS per-document input source flips the layout ~30 ms AFTER the first key when a field
    /// gets focus: the letter(s) already on screen are in the old alphabet. If the buffer is a
    /// 1-2 letter burst that was the very last thing the tap saw, retype it in the NEW layout
    /// through the ordinary pause/queue machinery (keys typed meanwhile queue, then drain through
    /// `drainPendingUserEvents`) and KEEP the buffer — the same keycodes, now read in the layout
    /// that is active. Returns true when the retype started (the caller must not wipe); on any
    /// other outcome the caller wipes exactly as before. A failed or cancelled retype wipes in
    /// its own completion, before the queued keys drain.
    private func retypeFirstBurstIfEligible(newLayout: KeyboardLayout?) -> Bool {
        let sources = languageDetector.inputSourceManager
        guard let newLayout, !isPaused, lastEventWasLetter,
              !buffer.isEmpty, buffer.count <= 2,
              pendingLeadingSymbols.isEmpty, runKeystrokes.count == buffer.count,
              let typedID = bufferTypedLayoutID, typedID != newLayout.id,
              let typedLayout = sources.layout(withID: typedID),
              autoCorrectionAllowedNow() else { return false }
        let age = CFAbsoluteTimeGetCurrent() - lastKeyTime
        guard age <= firstBurstRetypeWindow,
              keyDownsSinceActivation == buffer.count,
              CFAbsoluteTimeGetCurrent() - lastActivationAt <= firstBurstActivationWindow else { return false }
        let active = languageDetector.activeLayouts
        guard active.contains(where: { $0.id == typedID }),
              active.contains(where: { $0.id == newLayout.id }) else { return false }
        let keystrokes = buffer.currentWord()
        let onScreen = sources.convertKeystrokes(keystrokes, toLayout: typedLayout)
        let retyped = sources.convertKeystrokes(keystrokes, toLayout: newLayout)
        // Both layouts must render every key, and the text must actually differ.
        guard onScreen.count == keystrokes.count, retyped.count == keystrokes.count,
              onScreen != retyped else { return false }

        // Ownership: the retype erases `count` characters in whatever field is focused NOW. Within
        // the window the app can have moved focus to another populated field (no click, key or
        // activation reached us), and its text would be eaten. Retype only when the focused field
        // is readable and the text before its caret ends with exactly what these keys typed.
        // A field AX cannot read (terminals, some Electron apps) keeps today's behaviour: wipe.
        guard let focused = focusedTextProvider(),
              Self.textBeforeCaret(focused.text, caret: focused.caret).hasSuffix(onScreen) else {
            DebugLog.shared.log("KM", "first-burst retype: skipped (not verified)", level: .verbose)
            return false
        }

        let dtMs = Int((age * 1000).rounded())
        let count = keystrokes.count
        lastEventWasLetter = false
        isPaused = true
        textReplacer.replaceCurrentWord(
            length: count, replacement: retyped, targetLayout: newLayout,
            trailing: nil, trailingAlreadyOnScreen: false
        ) { [weak self] result in
            guard let self else { return }
            if result == .success {
                self.bufferTypedLayoutID = newLayout.id
                DebugLog.shared.log("KM", "first-burst retype: n=\(count) dt=\(dtMs)ms")
            } else {
                DebugLog.shared.log("KM", "first-burst retype: not applied (\(result)) n=\(count) dt=\(dtMs)ms")
                self.wipeContextAfterExternalLayoutChange()
            }
            self.finishReplacement()
        }
        return true
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

    func handleWordBoundary(
        trailing: String?, canAutoCorrect: Bool, keepForManualSwitch: Bool, triggerEvent: KeyEventSnapshot,
        triggerKeystroke: BufferedKeystroke? = nil, wordHadHeldKeys: Bool = false,
        wordAutorepeatCount: Int = 0, proseBoundary: Bool = false
    ) {
        // Compared at the history capture below: did THIS boundary write the word's ring slot?
        let ringWritesAtEntry = languageDetector.ringWriteCount
        let captured = buffer.currentWord()
        // Read before `pendingLeadingSymbols` is cleared below.
        let leadHasDigit = pendingLeadHasDigit
        let capitalizeSentenceStart = captured.isEmpty
            ? false : sentenceStartTracker.consumeForWord(leadHasDigit: leadHasDigit)
        if captured.isEmpty { switchUndoManager.invalidate() }
        let retyped = languageDetector.lastConvertedWord(keystrokes: captured) ?? ""
        let awaitingRetypeMatch = autoLearnTracker.isRetypePrefix(retyped)
        let learned = autoLearnTracker.confirmRetype(word: retyped, trailing: trailing)
        if awaitingRetypeMatch {
            DebugLog.shared.log("KM", "skip boundary correction: awaiting retype", level: .verbose)
        }
        if let learned {
            exceptionsService.learnException(
                original: learned.original,
                corrected: learned.corrected
            )
            DebugLog.shared.log("AUTOLEARN", "exact retype confirmed")
        }

        let snippetStarted = learned == nil
            && prefsService.isSnippetExpansionEnabled
            && pendingLeadingSymbols.isEmpty
            && !captured.isEmpty
            && expandSnippet(keystrokes: captured, trigger: trailing, triggerEvent: triggerEvent)

        lastRetypedTrigger = nil
        let languageReplacementStarted = !snippetStarted && canAutoCorrect
            && learned == nil && !awaitingRetypeMatch
            && !captured.isEmpty
            && processCurrentWord(
                trigger: trailing, triggerKeystroke: triggerKeystroke, triggerEvent: triggerEvent,
                wordAutorepeatCount: wordAutorepeatCount
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
        // must not clear the sentence-start intent before the next word
        // arrives — they are what confirms it (the gap after the period).
        // A conversion re-renders `trailing` for the TARGET layout (EN "?"
        // typed for RU "," is shown as ",") — 23.09.2026: judge the sentence
        // end from what actually landed on screen, not the source symbol.
        // English "." is kc47, a LETTER key ("ю" in Russian): it joins the word, so the boundary
        // only sees the Space. When that word ends in an unshifted kc47 on a Latin layout (outside
        // terminals, where ".." / "./x" are shell tokens), the Space is the period's gap.
        let englishPeriodThenSpace = trailing == " "
            && !snippetStarted && !languageReplacementStarted
            && triggerEvent.keycode != 53
            && captured.last.map { $0.keycode == 47 && !$0.flags.contains(.maskShift) } == true
            && languageDetector.inputSourceManager.currentLayout?.isEnglish == true
            && !LanguageDetector.isTerminalBundle(activeAppBundleID)
        if englishPeriodThenSpace {
            sentenceStartTracker.observeBoundary(".")
            sentenceStartTracker.observeEmptyBoundary(isGap: true, leadHasDigit: false)
        } else if !captured.isEmpty {
            sentenceStartTracker.observeBoundary(languageReplacementStarted ? (lastRetypedTrigger ?? trailing) : trailing)
        } else {
            // Esc types nothing, so it is not the gap after a period.
            sentenceStartTracker.observeEmptyBoundary(isGap: proseBoundary && triggerEvent.keycode != 53, leadHasDigit: leadHasDigit)
        }

        if replacementStarted {
            lastCompletedWord = nil
        } else if keepForManualSwitch, !captured.isEmpty, let trailing,
                  let typedLayout = languageDetector.inputSourceManager.currentLayout {
            // Captured NOW, right as the word completes — this IS the layout
            // it was typed on (any layout change mid-word would already have
            // cleared `buffer` via `layoutDidChange`). `pendingLeadingSymbols`
            // is read here, BEFORE it's cleared below.
            lastCompletedWord = (captured, trailing, typedLayout, pendingLeadingSymbols, triggerKeystroke)
            // The boundary can end without `detect` (over-long word, held keys, leading symbols,
            // retype paths, `!canAutoCorrect`) — then the history word owns NO ring slot.
            lastCompletedWordSlotWrite = languageDetector.ringWriteCount != ringWritesAtEntry
                ? languageDetector.ringWriteCount : nil
        } else if captured.isEmpty, keepForManualSwitch, trailing == " ", let history = lastCompletedWord,
                  history.trailing.isEmpty {
            // Double Shift re-armed the history with no trailing; this Space is the one that
            // follows the converted word on screen. Keep it so a second Double Shift toggles back.
            lastCompletedWord = (history.keystrokes, " ", history.typedLayout, history.leadingSymbols, triggerKeystroke)
        } else {
            lastCompletedWord = nil
        }

        // Game mode prose-exit signal (spec §5) — deliberately NOT folded
        // into `processCurrentWord`'s `.noSwitch` branch (where
        // `recordPersonalFrequencyBump` computes the same kind of
        // dictionary-ness check): that branch only runs when `canAutoCorrect`
        // is true, and game mode being ACTIVE is exactly what makes it false
        // (see `canAutoCorrect`'s `!gameActive`) — the one case this signal
        // exists to observe. So it's computed independently here, at any
        // real word boundary — `proseBoundary` now covers Enter/Tab too, not
        // just space: field 08.09.2026 showed chat apps close a word with
        // Enter, and the old `trailing == " "` check silently lost every one
        // of those words — gated behind `gameMode.isActiveForFrontmost()` (an
        // in-memory read, same cost class as the rest of this hot path) so
        // the extra dictionary lookups below are only ever paid while a
        // bundleID is actually flagged GAME — `noteProseWord` itself is a
        // no-op otherwise, so skipping the check when not needed changes
        // nothing observable.
        //
        // Own-layout reading is not enough on its own: field 08.09.2026, the
        // owner typed 13 Russian words in the WRONG (English) layout while
        // GAME was active ("lfdfq xnj nj lheujq" = "давай что то другой") —
        // own reading is dictionary-shaped exactly when the switcher ISN'T
        // needed, and junk exactly when it is. So a word also counts as
        // prose if it reads as a dictionary word in the other active layout.
        if proseBoundary, !captured.isEmpty, gameMode.isActiveForFrontmost(),
           let ownLayout = languageDetector.inputSourceManager.currentLayout {
            let ownText = languageDetector.inputSourceManager.convertKeystrokes(captured, toLayout: ownLayout)
            let ownCore = LanguageDetector.core(of: ownText)?.lowercased() ?? ""
            var isWord = !ownCore.isEmpty
                && languageDetector.isDictionaryWord(ownCore, language: ownLayout.languageCode)
            var coreLength = ownCore.count
            if !isWord, let other = languageDetector.activeLayouts.first(where: { $0.id != ownLayout.id }) {
                let otherText = languageDetector.inputSourceManager.convertKeystrokes(captured, toLayout: other)
                if let otherCore = LanguageDetector.core(of: otherText)?.lowercased(), !LanguageDetector.isMixedScript(otherCore),
                   languageDetector.isDictionaryWord(otherCore, language: other.languageCode) {
                    isWord = true
                    coreLength = otherCore.count
                }
            }
            gameMode.noteProseWord(isDictionaryWord: isWord, len: coreLength, hasHeldKeys: wordHadHeldKeys)
        }

        // Island: an instant correction (or a Double Shift "via buffer")
        // deferred its restore to this, the FIRST boundary reached since.
        // `proseBoundary` gates it to a real word break (space/Enter/Tab) —
        // punctuation closes the run too but does not end the sentence, so a
        // deferred restore just keeps waiting for the next one.
        if pendingIslandRestore {
            if proseBoundary {
                if !hasQueuedKeyDown {
                    restoreIsland(path: "deferred")
                } else {
                    DebugLog.shared.log("KM", "island: skipped reason=queueNonEmpty path=deferred", level: .verbose)
                    pendingIslandOwnerEnded = true
                }
            } else {
                DebugLog.shared.log("KM", "island: skipped reason=punctBoundary path=deferred", level: .verbose)
                pendingIslandOwnerEnded = true
            }
        }

        buffer.clear()
        pendingLeadingSymbols.removeAll()
    }

    @discardableResult
    private func expandSnippet(
        keystrokes: [BufferedKeystroke], trigger: String?, triggerEvent: KeyEventSnapshot
    ) -> Bool {
        guard !isPaused, let trigger,
              let layout = languageDetector.inputSourceManager.currentLayout else { return false }
        guard !inPostReplacementCooldown else {
            DebugLog.shared.log("KM", "snippet skipped: post-replacement cooldown", level: .verbose)
            return false
        }
        let typed = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        guard let replacement = snippetService.replacement(for: typed), replacement != typed else {
            return false
        }

        isPaused = true
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(triggerEvent)
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
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                DebugLog.shared.log("SNIPPET", "expansion aborted: layout verification failed")
            case .cancelled:
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                DebugLog.shared.log("SNIPPET", "expansion cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    @discardableResult
    private func applySmartCase(
        keystrokes: [BufferedKeystroke], trigger: String?, triggerEvent: KeyEventSnapshot,
        capitalizeSentenceStart: Bool
    ) -> Bool {
        guard !isPaused, let trigger,
              let layout = languageDetector.inputSourceManager.currentLayout else { return false }
        guard !inPostReplacementCooldown else {
            DebugLog.shared.log("KM", "smart case skipped: post-replacement cooldown", level: .verbose)
            return false
        }
        let typed = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
        guard !exceptionsService.isWordExcepted(typed),
              let replacement = SmartCaseNormalizer.normalized(
                  typed, capitalizeSentenceStart: capitalizeSentenceStart
              ) else { return false }

        isPaused = true
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(triggerEvent)
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
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                DebugLog.shared.log("SMARTCASE", "normalization aborted: layout verification failed")
            case .cancelled:
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
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
    func logInstantSilence(_ reason: InstantCorrectionAnalyzer.SilenceReason?, len: Int) {
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
    func tryInstantCorrection(triggerEvent: KeyEventSnapshot) {
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
        pendingUserEvents.enqueueFront(triggerEvent)
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
                // Island: the word's own boundary hasn't happened yet
                // (instant fires mid-word) — defer to `handleWordBoundary`,
                // which restores once that boundary actually arrives.
                //
                // The context is captured now (the word is not in the ring yet). The word's own
                // `(target, corrected)` slot is written at ITS BOUNDARY from the gate's
                // `landedLang` (`processCurrentWord`), like every other word — a Backspace or a
                // Double Shift before the boundary can still change where it lands.
                self.pendingIslandContext = Array(self.languageDetector.contextSlots.suffix(2))
                self.instantCorrectionGate.markLanded(lang: result.layout.languageCode)
                // Auto-learn needs the WHOLE word (the prefix typed so far would be disarmed by the
                // next letter): the word's boundary arms the tracker from these layouts.
                if !original.isEmpty {
                    self.instantCorrectionGate.markLearnable(
                        sourceLayoutID: currentLayout.id, targetLayoutID: result.layout.id
                    )
                }
                self.pendingIslandTarget = result.layout.languageCode
                self.pendingIslandOwnerEnded = false
                self.pendingIslandRestore = true
            case .layoutSwitchFailed:
                self.instantCorrectionGate.reset()
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                DebugLog.shared.log("KM", "instant correction aborted: layout switch verification failed")
            case .cancelled:
                // Same reset as .layoutSwitchFailed above — markCorrected()
                // above ran unconditionally before this async call started,
                // so a cancelled attempt must undo it too, or the word's own
                // boundary silently skips ("skip boundary correction:
                // already instant-corrected") a correction that never
                // actually happened (plan 004, defect 2).
                self.instantCorrectionGate.reset()
                self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                DebugLog.shared.log("KM", "instant correction cancelled: editing context changed")
            }
            self.finishReplacement()
        }
    }

    /// True during the brief settling window `finishReplacement` opens after
    /// EVERY replacement (auto or manual — see its own comment). Read by the
    /// three automatic features `canFireAutoCorrection` below does NOT cover
    /// (`applySmartCase`, `applyYoficator`, `expandSnippet`): a key replayed
    /// out of the pause queue can complete a LATER word's own boundary
    /// before the settling window closes, and none of these three had a
    /// cooldown check of their own — a replayed burst could launch one of
    /// them mid-burst (plan 004, defect 1).
    private var inPostReplacementCooldown: Bool {
        CFAbsoluteTimeGetCurrent() < autoCorrectionCooldownUntil
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
    func logContextWipe(_ reason: String) {
        guard !buffer.isEmpty || !pendingLeadingSymbols.isEmpty
            || !runKeystrokes.isEmpty || lastCompletedWord != nil else { return }
        DebugLog.shared.log(
            "KM",
            "buffer wiped: reason=\(reason) len=\(buffer.currentWord().count)"
                + " lead=\(pendingLeadingSymbols.count) run=\(runKeystrokes.count)"
                + " history=\(lastCompletedWord == nil ? 0 : 1)"
        )
    }

    /// The ONE place that drops parts of the typed-word model when the editing context ends
    /// (plan 007). WHAT each reason drops is `ContextResetPolicy.scope(for:)`; the reset bodies
    /// are independent of each other (none reads another component), so the fixed order below is
    /// safe. The wipe log reads the model, so it runs before any clear.
    func resetTypingContext(_ reason: ContextResetReason) {
        if reason.logsWipe { logContextWipe(reason.logLabel) }
        let scope = ContextResetPolicy.scope(for: reason)
        if scope.contains(.wordModel) { buffer.clear() }
        if scope.contains(.runAndLead) {
            pendingLeadingSymbols.removeAll()
            runKeystrokes.removeAll()
            wordAutorepeatCount = 0
        }
        if scope.contains(.history) { lastCompletedWord = nil }
        if scope.contains(.autoLearn) { autoLearnTracker.cancel() }
        if scope.contains(.undoRecord) { switchUndoManager.invalidate() }
        if scope.contains(.instantGate) { instantCorrectionGate.reset() }
        if scope.contains(.sentence) { sentenceStartTracker.reset() }
        if scope.contains(.detectorContext) { languageDetector.resetContext() }
        if scope.contains(.feedback) { feedbackTracker.reset() }
        if scope.contains(.island) {
            pendingIslandRestore = false
            pendingIslandTarget = nil
            pendingIslandContext = nil
            pendingIslandOwnerEnded = false
        }
    }

    /// A key was added to the buffer while an island deferred by an EARLIER, finished word is
    /// still pending: if it renders a LETTER on the active layout, the owner is typing the next
    /// word of a run and the frozen context must not be restored. Layout-dependent punctuation
    /// (kc47 is "." on en, "ю" on ru) renders no letter and leaves the island alone. Called for
    /// every letter-path key, so ".hello" still cancels on the "h".
    func cancelStalePendingIsland(keycode: UInt16, flags: CGEventFlags, layout: KeyboardLayout?) {
        guard pendingIslandRestore, pendingIslandOwnerEnded else { return }
        // Unknown rendering (no layout / no lookup): treat as a letter, the pre-existing behaviour.
        if let layout,
           let rendered = languageDetector.inputSourceManager.characterForKeycode(keycode, layout: layout, flags: flags),
           rendered.first?.isLetter != true {
            return
        }
        pendingIslandRestore = false
        pendingIslandTarget = nil
        pendingIslandContext = nil
        pendingIslandOwnerEnded = false
        DebugLog.shared.log("KM", "island: skipped reason=nextWordStarted", level: .verbose)
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

    /// Pure decision core of `normalizedLearnableCore`, extracted so
    /// `ShortTokenTests.swift` can exercise it directly with real tokens
    /// instead of driving a live `KeyboardMonitor` through a synthetic
    /// CGEventTap (unavailable in this headless harness on macOS 27 beta —
    /// same reason `ReplacementAtomicityGuardTests` reads source instead).
    /// `isDictionaryWord` is injected rather than calling
    /// `LanguageDetector.isDictionaryWord` directly so tests can wire a real
    /// `LanguageDetector` OR a small closed fixture, whichever a given case
    /// needs — identical contract either way (`LanguageDetector.isDictionaryWord`
    /// is itself just `scoreWord(...) > 0`, no state).
    ///
    /// Returns the plain lowercased core to learn, or `nil` with the exact
    /// verbose-log reason `normalizedLearnableCore` below prints (tests
    /// assert on the reason value directly, not on log output).
    ///
    /// - Parameters:
    ///   - own: the SAME keystrokes' reading in the layout they were
    ///     actually typed on, BEFORE this Double Shift converted them.
    ///   - ownLang: that source layout's language code.
    static func learnableCoreDecision(
        from text: String, lang: String, own: String, ownLang: String, resynced: Bool,
        isDictionaryWord: (_ word: String, _ language: String) -> Bool
    ) -> (core: String?, rejectReason: String?) {
        guard !resynced else { return (nil, "resynced") }
        guard let core = LanguageDetector.core(of: text)?.lowercased(), !core.isEmpty,
              !LanguageDetector.isMixedScript(core) else {
            return (nil, "mixedRun")
        }
        // Short-token fix (field data 08-10.09.2026): a single letter is
        // still pointless to store (neither application path — instant
        // minLength=4, boundary via `learnedHitApplies` now >=2 — can ever
        // fire on length 1), but length 2 IS eligible now; see the
        // `ownIsWord` guard below for why that needed its own defense
        // first.
        guard core.count >= 2 else { return (nil, "belowMinLen") }
        guard !LanguageDetector.isReservedForDisambiguation(core, language: lang) else {
            return (nil, "conflictPair")
        }
        // A 2-letter target core is short enough that the SAME two keys can
        // also read as a genuine dictionary word of the layout they were
        // typed on — «он» typed on ru, Double Shift-flipped to "jy" (its en
        // reading), would otherwise learn "jy"→«он» and silently "correct"
        // every future honest «он». `own`/`ownLang` is the only place that
        // knows what the owner actually had on screen before the flip —
        // `text`/`lang` alone (the TARGET side) can't see this. Length ≥3
        // is unaffected — this guard runs ONLY for the newly-opened length.
        // Also fires (conservatively) if the own side has no clean letter
        // core at all — an ambiguous "what was on screen" is reason enough
        // not to learn.
        if core.count == 2 {
            guard let ownCore = LanguageDetector.core(of: own)?.lowercased(), !ownCore.isEmpty,
                  !isDictionaryWord(ownCore, ownLang) else {
                return (nil, "ownIsWord")
            }
        }
        return (core, nil)
    }

    /// Mechanism A's write-time normalization (learning_spec.md "Механизм A
    /// → Запись"). Thin instance wrapper around `learnableCoreDecision`:
    /// adds the `isLearningEnabled` gate (instance state, no pure equivalent
    /// worth threading through) and turns a rejection into the verbose log
    /// line. Never logs the word itself — lengths/reasons only.
    ///
    /// - Parameters:
    ///   - own: the SAME keystrokes' reading in the layout they were
    ///     actually typed on, BEFORE this Double Shift converted them — the
    ///     callers already have this (`onScreen`/`originalWordOnly`, the
    ///     "original" side of their own `switchUndoManager.record`/
    ///     `handleDoubleShiftClassification` calls).
    ///   - ownLang: that source layout's language code.
    func normalizedLearnableCore(from text: String, lang: String, own: String, ownLang: String, resynced: Bool) -> String? {
        guard prefsService.isLearningEnabled else {
            DebugLog.shared.log("KM", "learned: skipped reason=disabled", level: .verbose)
            return nil
        }
        let decision = Self.learnableCoreDecision(
            from: text, lang: lang, own: own, ownLang: ownLang, resynced: resynced,
            isDictionaryWord: { [languageDetector] word, language in
                languageDetector.isDictionaryWord(word, language: language)
            }
        )
        if let reason = decision.rejectReason {
            DebugLog.shared.log("KM", "learned: skipped reason=\(reason)", level: .verbose)
        }
        return decision.core
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
    func handleDoubleShiftClassification(
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

    func invalidateEditingContext(reason: String = "unspecified") {
        // Plan 013 B: before the isPaused early return — a click/app switch mid-pause must void it too.
        chordComma = nil
        if isPaused {
            invalidateAfterReplacement = true
            textReplacer.cancelCurrentReplacement()
            return
        }
        // Mechanism B reset point 1/7 (learning_spec.md): covers every
        // reason routed through here — app-activated, mouse-click,
        // modifier-shortcut, paste-no-format, blocked-app-hotkey.
        resetTypingContext(.editingInvalidated(reason))
    }

    /// Island feature (v0.11.0, docs/HISTORY.md "v0.11.0 (10.09.2026)"): snap the layout back to
    /// whatever the owner was writing in before a single foreign word got
    /// corrected — called once the correction is fully committed (its word
    /// boundary reached, or immediately for Double Shift, where the word is
    /// already complete). Never touches text; only ever switches the active
    /// input source, exactly like an ordinary manual switch.
    ///
    /// `path` is `"boundary"` (word-boundary auto-correction, queue was
    /// already empty), `"deferred"` (an instant correction's boundary
    /// arrived later — queue-non-empty or punctuation deferred it once
    /// already) or `"ds"` (Double Shift). Logged, not branched on, except
    /// for the ring-inclusion question below.
    func restoreIsland(path: String) {
        guard let target = pendingIslandTarget else {
            DebugLog.shared.log("KM", "island: skipped reason=noContext path=\(path)", level: .verbose)
            pendingIslandRestore = false
            pendingIslandOwnerEnded = false
            return
        }
        // Read BEFORE the clear: the context was captured when this island was armed.
        let context = pendingIslandContext ?? []
        pendingIslandTarget = nil
        pendingIslandContext = nil
        pendingIslandRestore = false
        pendingIslandOwnerEnded = false

        // Terminals: the island makes NO text edit, only switches the input
        // source at a word boundary, and a wrong one is repaired by the same
        // instant/boundary correction that already runs there — so it obeys a
        // preference (default on) instead of a hard block. Read straight from
        // `prefsService` (UserDefaults): restoreIsland runs once per corrected
        // word, not per key, so this is off the per-key hot path.
        let isTerminal = LanguageDetector.isTerminalBundle(activeAppBundleID)
        let islandBlockedInTerminal = isTerminal && !prefsService.isIslandInTerminalsEnabled
        guard !islandBlockedInTerminal else {
            DebugLog.shared.log("KM", "island: skipped reason=terminal path=\(path)", level: .verbose)
            return
        }

        // `context` (captured at arming) is the ≤2 ring slots immediately before the corrected word.
        let ctxDescription = context.map { "\($0.lang)\($0.corrected ? "*" : "")" }.joined(separator: ",")

        guard let restoreLang = IslandPolicy.shouldRestore(
            context: context, target: target, isTerminal: islandBlockedInTerminal
        ) else {
            // `IslandPolicy` only reports pass/fail (see its own doc comment
            // on why it stays a pure String?) — reclassified here, read-only,
            // purely for the verbose trace; the gate itself already ran above.
            let reason: String
            let previous = context.suffix(2)
            if context.count < 2 {
                reason = "noContext"
            } else if previous.first?.lang != previous.last?.lang
                || previous.first?.corrected == true || previous.last?.corrected == true {
                reason = "secondInRun"
            } else if previous.first?.lang == target {
                reason = "sameLang"
            } else {
                reason = "noContext"
            }
            DebugLog.shared.log(
                "KM", "island: skipped reason=\(reason) path=\(path) ctx=[\(ctxDescription)]", level: .verbose
            )
            return
        }
        guard let layout = languageDetector.activeLayouts.first(where: { $0.languageCode == restoreLang }) else {
            DebugLog.shared.log("KM", "island: skipped reason=noLayout path=\(path) lang=\(restoreLang)", level: .verbose)
            return
        }
        guard languageDetector.inputSourceManager.switchTo(layout) else {
            DebugLog.shared.log("KM", "island: switch failed reason=switchFailed path=\(path) lang=\(restoreLang)")
            return
        }
        // selfInitiated — `layoutDidChange` ignores our own switch and never
        // wipes `buffer`/`runKeystrokes` for it (RC-3, see its doc comment).
        languageDetector.setContextLanguage(restoreLang)
        DebugLog.shared.log(
            "KM", "island: restored \(restoreLang)←\(target) path=\(path)\(isTerminal ? " term=1" : "") ctx=[\(ctxDescription)]"
        )
    }

    /// - Parameter trigger: the character the user just typed that caused us to
    ///                      consider the buffered word complete (space / `.` / `;`
    ///                      etc). It already landed in the text field, so the
    ///                      replacer must backspace over it and re-type it.
    ///                      Pass nil only if nothing was printed after the word.
    /// - Parameter wordAutorepeatCount: captured by the caller BEFORE it resets
    ///                      the live counter for the next word — reading
    ///                      `self.wordAutorepeatCount` here would always see 0.
    @discardableResult
    private func processCurrentWord(
        trigger: String?, triggerKeystroke: BufferedKeystroke? = nil, triggerEvent: KeyEventSnapshot,
        wordAutorepeatCount: Int
    ) -> Bool {
        guard !isPaused else { return false }
        let instantLanded = instantCorrectionGate.landedLang
        let instantLearn = instantCorrectionGate.learnLayouts
        if instantCorrectionGate.consumeIfCorrected() {
            // Delete-and-retype learning for an instant correction: arm with the whole word.
            let sources = languageDetector.inputSourceManager
            if let instantLearn, let source = sources.layout(withID: instantLearn.source),
               let target = sources.layout(withID: instantLearn.target) {
                let word = buffer.currentWord()
                autoLearnTracker.recordCorrection(
                    original: sources.convertKeystrokes(word, toLayout: source),
                    corrected: sources.convertKeystrokes(word, toLayout: target),
                    trailing: trigger
                )
            }
            // The word's one ring slot: it landed in the instant correction's target.
            if let instantLanded {
                languageDetector.recordLandedWord(lang: instantLanded, corrected: true, replacingLast: false)
            }
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

        // Captured BEFORE `detect`: when it is nil `detect` pushes no slot, and a `replacingLast`
        // veto rewrite would clobber the PREVIOUS word's slot.
        let ownLang = languageDetector.inputSourceManager.currentLayout?.languageCode
        let result = languageDetector.detect(keystrokes: keystrokes)
        // `detect` pushed `(target, corrected)`; a veto leaves the word as typed → rewrite to (own, clean).
        let recordVetoed = { [languageDetector] in
            if let ownLang {
                languageDetector.recordLandedWord(lang: ownLang, corrected: false, replacingLast: true)
            }
        }
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
                recordVetoed()
                return false
            }
            let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes)
            if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
                DebugLog.shared.log("KM", "skip: auto-learned exception")
                recordVetoed()
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
                recordVetoed()
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

            guard canFireAutoCorrection(branch: "boundary correction") else {
                recordVetoed()
                return false
            }

            // The word itself is already on screen (typed letter-by-letter
            // normally), but the trigger that just completed it (space/
            // punctuation) hasn't been delivered yet — headInsert tap runs
            // before delivery. Suppress it so it can never race our own
            // backspaces (RC-1); it's retyped as part of the payload instead.
            isPaused = true
            lastRetypedTrigger = retypedTrigger
            avalancheGuard.recordFired()
            suppressCurrentEvent = true
            pendingUserEvents.enqueueFront(triggerEvent)
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
                    // Island: `languageDetector.detect` ran synchronously
                    // above (before this completion), so the ring already
                    // carries this word's own `(target, corrected: true)`
                    // entry. The word is fully committed now — restore
                    // immediately if the queue is clear, otherwise defer to
                    // `handleWordBoundary` the same way instant correction does.
                    //
                    // Don't drop this gate again: 0.11.2 restored
                    // unconditionally and the field log of 19–20.09.2026
                    // showed 0 of 4 such restores helping. A non-empty queue
                    // means the owner is already typing the next word, and
                    // English comes in runs («uni hub») — flipping back under
                    // their fingers turned «hub» into «руб» and bounced the
                    // word after it. A smarter island needs run awareness,
                    // not an earlier switch.
                    //
                    // The context is the 2 slots before this word's own (last) slot. A queued
                    // keyUp alone does not defer (`hasQueuedKeyDown`): the next word is only
                    // "being typed" once a keyDown is waiting.
                    self.pendingIslandContext = Array(self.languageDetector.contextSlots.dropLast().suffix(2))
                    self.pendingIslandTarget = layout.languageCode
                    if !self.hasQueuedKeyDown {
                        self.restoreIsland(path: "boundary")
                    } else {
                        self.pendingIslandOwnerEnded = true // its boundary is behind us
                        self.pendingIslandRestore = true
                        DebugLog.shared.log("KM", "island: skipped reason=queueNonEmpty path=boundary", level: .verbose)
                    }
                case .layoutSwitchFailed:
                    // `detect` already pushed `(target, corrected)` for this word; it stayed as typed.
                    self.languageDetector.recordLandedWord(
                        lang: sourceLayout.languageCode, corrected: false, replacingLast: true
                    )
                    // Layout switch failed → nothing was retyped, the word is
                    // still on screen in `sourceLayout` exactly as typed — so
                    // history keeps the ORIGINAL (source-rendered) `trigger`,
                    // not `retypedTrigger` (which was rendered for the target
                    // layout that never actually took effect).
                    if let trigger {
                        self.lastCompletedWord = (keystrokes, trigger, sourceLayout, leadingSymbols, triggerKeystroke)
                        // `detect` pushed this word's slot and the line above rewrote it.
                        self.lastCompletedWordSlotWrite = self.languageDetector.ringWriteCount
                    }
                    self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                    DebugLog.shared.log("KM", "correction aborted: layout switch verification failed")
                case .cancelled:
                    self.languageDetector.recordLandedWord(
                        lang: sourceLayout.languageCode, corrected: false, replacingLast: true
                    )
                    self.pendingUserEvents.replaceFront(with: triggerEvent.asOurs)
                    DebugLog.shared.log("KM", "correction cancelled: editing context changed")
                }
                self.finishReplacement()
            }
            return true
        }
    }

    @discardableResult
    private func applyYoficator(keystrokes: [BufferedKeystroke], trigger: String?) -> Bool {
        guard !inPostReplacementCooldown else {
            DebugLog.shared.log("KM", "yoficator skipped: post-replacement cooldown", level: .verbose)
            return false
        }
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
        // Undo already switches the layout back to `originalLayout` below —
        // island policy has no business layering another switch on top of
        // it, but the CONTEXT it reads must not still think the (now
        // reverted) correction happened, or the next real correction could
        // misjudge the words around it.
        resetTypingContext(.undo)

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

    // MARK: - Chorded comma repair (plan 013, step B)

    /// Arms the candidate right after a kc44 keyDown was handled — only for a plain "." that
    /// the boundary logic did not already turn into a replacement. Decided by what the layout
    /// actually prints (`characterForKeycode`), never by a layout name: EN/ABC prints "/" and "?"
    /// there and is excluded by the same check.
    func armChordCommaIfEligible(keycode: UInt16, flags: CGEventFlags, canAutoCorrect: Bool) {
        guard keycode == 44, canAutoCorrect, !isPaused,
              flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]).isEmpty,
              let layout = languageDetector.inputSourceManager.currentLayout else { return }
        let sources = languageDetector.inputSourceManager
        guard sources.characterForKeycode(keycode, layout: layout, flags: []) == ".",
              sources.characterForKeycode(keycode, layout: layout, flags: .maskShift) == "," else { return }
        chordComma = ChordCommaCandidate(
            armedAt: CFAbsoluteTimeGetCurrent(), layoutID: layout.id, shiftDownAt: nil
        )
    }

    /// Shift transitions for a pending chord candidate (called from `handle` after the hotkey
    /// manager saw the same event). Down within the window → mark the candidate and tell the
    /// hotkey manager this Shift is not a bare tap; release of that same Shift with no key
    /// pressed in between (any keyDown cleared the candidate) → repair.
    func noteChordCommaFlags(keycode: UInt16, flags: CGEventFlags) {
        guard var candidate = chordComma else { return }
        let isShiftKey = keycode == 56 || keycode == 60
        let otherModifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        guard isShiftKey, otherModifiers.isEmpty, !isPaused else {
            chordComma = nil
            return
        }
        let shiftHeld = flags.contains(.maskShift)
        if candidate.shiftDownAt == nil {
            let now = CFAbsoluteTimeGetCurrent()
            guard shiftHeld, now - candidate.armedAt <= chordCommaWindow else {
                chordComma = nil
                return
            }
            candidate.shiftDownAt = now
            chordComma = candidate
            hotkeyManager?.suppressBareTapForCurrentShiftCycle()
        } else if shiftHeld {
            // A second Shift joined — not the plain gesture this repair is for.
            chordComma = nil
        } else {
            chordComma = nil
            if let downAt = candidate.shiftDownAt,
               CFAbsoluteTimeGetCurrent() - downAt > chordCommaMaxHold {
                DebugLog.shared.log("KM", "chord comma: skipped (Shift held too long)", level: .verbose)
                return
            }
            repairChordComma(candidate)
        }
    }

    /// Erases the "." and types "," through the ordinary replacement machinery (keys typed
    /// meanwhile are queued, then analysed and replayed by `finishReplacement`). The layout is
    /// never touched: target = the layout the "." was typed in.
    private func repairChordComma(_ candidate: ChordCommaCandidate) {
        guard let shiftDownAt = candidate.shiftDownAt else { return }
        let dtMs = Int(((shiftDownAt - candidate.armedAt) * 1000).rounded())
        guard !isPaused,
              let layout = languageDetector.inputSourceManager.currentLayout,
              layout.id == candidate.layoutID else {
            DebugLog.shared.log("KM", "chord comma: skipped dt=\(dtMs)ms (replacement active or layout changed)")
            return
        }
        isPaused = true
        textReplacer.replaceCurrentWord(
            length: 1, replacement: ",", targetLayout: layout,
            trailing: nil, trailingAlreadyOnScreen: false
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // The model must read the symbol as it now is on screen: a "," ends no sentence.
                self.sentenceStartTracker.reobserveTrailing(",")
                let shifted = { (key: BufferedKeystroke) -> BufferedKeystroke in
                    var flags = key.flags
                    flags.insert(.maskShift)
                    return BufferedKeystroke(keycode: key.keycode, flags: flags)
                }
                if let history = self.lastCompletedWord, history.trailing == ".",
                   history.trailingKeystroke?.keycode == 44, let key = history.trailingKeystroke {
                    self.lastCompletedWord?.trailing = ","
                    self.lastCompletedWord?.trailingKeystroke = shifted(key)
                }
                if let last = self.runKeystrokes.last, last.keycode == 44 {
                    self.runKeystrokes[self.runKeystrokes.count - 1] = shifted(last)
                }
                if let last = self.pendingLeadingSymbols.last, last.keycode == 44 {
                    self.pendingLeadingSymbols[self.pendingLeadingSymbols.count - 1] = shifted(last)
                }
                DebugLog.shared.log("KM", "chord comma: repaired dt=\(dtMs)ms")
            case .layoutSwitchFailed:
                DebugLog.shared.log("KM", "chord comma: aborted dt=\(dtMs)ms (layout verification failed)")
            case .cancelled:
                DebugLog.shared.log("KM", "chord comma: cancelled dt=\(dtMs)ms (editing context changed)")
            }
            self.finishReplacement()
        }
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

    // MARK: - Tap delivery latency probe (diagnostic only — Plan 006 Step 5)

    /// `recordCallbackDuration` above measures our OWN handler time. It says
    /// nothing about how LATE a key already was when the callback started —
    /// the tap runs on the main run loop, shared with UI, so a busy UI frame
    /// can delay delivery before our code ever sees the event. Which of the
    /// two candidate meanings of `CGEvent.timestamp` applies on this Mac is
    /// unknown ahead of time: Apple's docs say nanoseconds since boot
    /// (interpretation A), but Apple Silicon has been observed to hand back
    /// raw `mach_absolute_time` ticks instead (interpretation B — needs
    /// `mach_timebase_info` to convert to ns). Decided once, from the first
    /// `tapAgeProbeCount` keyDowns after launch; `.none` disables the check
    /// permanently if neither interpretation ever produced a plausible age.
    enum TapAgeInterpretation: Equatable {
        case a
        case b
        case none
    }

    private var tapAgeInterpretation: TapAgeInterpretation?
    private var tapAgeProbesA: [Double] = []
    private var tapAgeProbesB: [Double] = []
    private let tapAgeProbeCount = 5
    private var slowKeyDeliveryCount = 0
    private var lastSlowKeyDeliveryLogAt: CFAbsoluteTime = 0

    /// Pure decision, unit-tested without a live CGEventTap: which
    /// interpretation had EVERY one of its probe ages inside a plausible
    /// 0…1000ms window. A is preferred when both qualify — it matches
    /// Apple's documented meaning of `CGEvent.timestamp`.
    static func chooseTimestampInterpretation(
        probesA: [Double], probesB: [Double]
    ) -> TapAgeInterpretation {
        func allPlausible(_ probes: [Double]) -> Bool {
            !probes.isEmpty && probes.allSatisfy { $0 >= 0 && $0 <= 1000 }
        }
        if allPlausible(probesA) { return .a }
        if allPlausible(probesB) { return .b }
        return .none
    }

    /// Called by `eventTapCallback` for every PHYSICAL keyDown, with the raw
    /// `CGEvent.timestamp` still in scope — read there, never inside
    /// `handle(_:)`. Our own synthetic (`.ours`) and replayed (`.replayedUser`)
    /// keys keep their original timestamp, so their "age" would measure our
    /// own queue/replacement, not system delivery latency. No behaviour
    /// change: this only measures and logs.
    func noteTapDeliveryAge(eventTimestamp: UInt64) {
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let ageA_ms = Double(nowNs >= eventTimestamp ? nowNs - eventTimestamp : 0) / 1_000_000

        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticksAsNs = timebase.denom > 0
            ? eventTimestamp * UInt64(timebase.numer) / UInt64(timebase.denom)
            : eventTimestamp
        let ageB_ms = Double(nowNs >= ticksAsNs ? nowNs - ticksAsNs : 0) / 1_000_000

        if let tapAgeInterpretation {
            guard tapAgeInterpretation != .none else { return }
            let age = tapAgeInterpretation == .a ? ageA_ms : ageB_ms
            guard age > 15 else { return }
            slowKeyDeliveryCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastSlowKeyDeliveryLogAt >= 1 else { return }
            lastSlowKeyDeliveryLogAt = now
            DebugLog.shared.log(
                "KM",
                "WARNING: slow key delivery \(Int(age.rounded()))ms count=\(slowKeyDeliveryCount)"
            )
            return
        }

        tapAgeProbesA.append(ageA_ms)
        tapAgeProbesB.append(ageB_ms)
        DebugLog.shared.log(
            "KM",
            "tap age probe a_ms=\(String(format: "%.1f", ageA_ms)) b_ms=\(String(format: "%.1f", ageB_ms))",
            level: .verbose
        )
        guard tapAgeProbesA.count >= tapAgeProbeCount else { return }
        let chosen = Self.chooseTimestampInterpretation(probesA: tapAgeProbesA, probesB: tapAgeProbesB)
        tapAgeInterpretation = chosen
        if chosen == .none {
            DebugLog.shared.log("KM", "tap age: units unknown")
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let isDisableNotification = type == .tapDisabledByTimeout
        || type == .tapDisabledByUserInput
    // Built once here, skipped only for a disable notification (which carries
    // no real keystroke fields) — every check below reads this snapshot
    // instead of the raw CGEvent.
    let snapshot = isDisableNotification ? nil : KeyEventSnapshot(type: type, event: event)
    // Plan 006 Step 5 (diagnostic only, no behaviour change): how old the
    // event already is by the time the callback starts. Physical keys only —
    // `.ours`/`.replayedUser` carry their original timestamp. `event.timestamp`
    // is read HERE — never inside `handle(_:)`, which only ever sees the
    // snapshot built above.
    if type == .keyDown, snapshot?.route == .physical {
        monitor.noteTapDeliveryAge(eventTimestamp: event.timestamp)
    }
    if let snapshot, snapshot.route == .ours {
        return Unmanaged.passUnretained(event)
    }
    if let snapshot, monitor.queueIfReplacementActive(snapshot) { return nil }
    let callbackStart = CFAbsoluteTimeGetCurrent()
    let suppressHandledShortcut = snapshot.map { monitor.handlesShortcut($0) } ?? false
    if isDisableNotification {
        monitor.handleTapDisabled(type)
    } else if let snapshot {
        monitor.handle(snapshot)
    }
    let suppressTrigger = monitor.consumeSuppressCurrentEvent()
    let suppressed = suppressHandledShortcut || suppressTrigger
    monitor.recordCallbackDuration(CFAbsoluteTimeGetCurrent() - callbackStart, type: type, suppressed: suppressed)
    return suppressed ? nil : Unmanaged.passUnretained(event)
}
