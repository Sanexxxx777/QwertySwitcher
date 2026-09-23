#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


// MARK: - KeyboardMonitor integration harness (headless — no GUI, no real CGEventTap)
//
// Everything above tests pure functions or components in isolation. This
// section drives a REAL `KeyboardMonitor` with synthetic CGEvents through
// the exact contract the live CGEventTap callback uses (`eventTapCallback`
// at the bottom of KeyboardMonitor.swift), and substitutes a `TextReplacing`
// fake that models "what's on screen" as a plain string instead of posting
// real CGEvents. This is the missing layer between unit tests
// (LanguageDetector/InstantCorrectionAnalyzer, above) and a live GUI — it
// catches bugs that only exist at the STITCH between buffering, leading-
// symbol tracking and the backspace/retype transaction, which is exactly
// where the ".yexit" bug lived: `swapLastWordInBuffer` never read
// `pendingLeadingSymbols` at all (fixed in KeyboardMonitor.swift alongside
// this harness).

/// Deterministic stand-in for `TextReplacer`: models "what's on screen" as a
/// plain string instead of posting real CGEvents. Interprets `length`/
/// `trailing`/`trailingAlreadyOnScreen` via the SAME `TextReplacementPlan`
/// production code uses, so a wrong backspace-count formula in
/// `KeyboardMonitor` shows up here exactly as it would on a real screen.
final class FakeTextReplacer: TextReplacing {
    /// How `replaceCurrentWord` resolves. Default mirrors the ONLY behaviour
    /// this class had before plan 004 (synchronous success), so every
    /// pre-existing test keeps running byte-for-byte the same. `.deferred`
    /// holds the transaction open (`KeyboardMonitor.isPaused` stays true)
    /// until the test explicitly calls
    /// `KeyboardMonitorHarness.completePendingReplacement` — modelling a
    /// replacement genuinely in flight while more keys arrive, which no
    /// synchronous-only fake could ever reach.
    enum CompletionMode {
        case immediate(TextReplacer.Result)
        case deferred
    }

    private(set) var screen: String = ""
    private(set) var invocationCount = 0
    private let inputSources: InputSourceManager
    var mode: CompletionMode = .immediate(.success)

    /// Set only while a `.deferred` call is waiting on `completePending`;
    /// consumed (and cleared) by it. Holds the ORIGINAL completion so it can
    /// be invoked later with whichever result the test picks, plus the
    /// screen mutation — applied only for `.success`, since a real failure
    /// happens before the first destructive step (layout switch
    /// verification, in `TextReplacer`) and changes nothing on screen.
    private var pending: (completion: (TextReplacer.Result) -> Void, applySuccess: () -> Void)?

    init(inputSources: InputSourceManager) {
        self.inputSources = inputSources
    }

    func replaceCurrentWord(
        length: Int, replacement: String, targetLayout: KeyboardLayout,
        trailing: String?, trailingAlreadyOnScreen: Bool,
        completion: @escaping (TextReplacer.Result) -> Void
    ) {
        invocationCount += 1
        let applySuccess: () -> Void = { [weak self] in
            guard let self else { return }
            // The real TextReplacer switches the input source FIRST, before any
            // backspace/retype — matters here too: any further keys the harness
            // presses after this correction (mid-word instant-correction cases
            // keep typing the rest of the word) must render under the NEW
            // layout, exactly like a real app would see them.
            self.inputSources.switchTo(targetLayout)
            let plan = TextReplacementPlan(
                originalLength: length, replacement: replacement, trailing: trailing,
                trailingAlreadyOnScreen: trailingAlreadyOnScreen
            )
            // Clamped to what's actually on screen — exactly what a real text
            // field does once there's nothing left to delete. A backspace count
            // that's too high WITHIN the existing text (the interesting bug
            // class) still eats into whatever precedes the word, same as live.
            let backspaces = min(plan.backspaceCount, self.screen.count)
            self.screen.removeLast(backspaces)
            self.screen += plan.payload
        }
        switch mode {
        case .immediate(let result):
            if result == .success { applySuccess() }
            completion(result)
        case .deferred:
            pending = (completion: completion, applySuccess: applySuccess)
        }
    }

    /// Resolves the transaction `replaceCurrentWord` left open under
    /// `.deferred`: applies the screen mutation for `.success` only, then
    /// calls the ORIGINAL completion with `result`. A no-op if nothing is
    /// pending.
    func completePending(with result: TextReplacer.Result = .success) {
        guard let pending else { return }
        self.pending = nil
        if result == .success { pending.applySuccess() }
        pending.completion(result)
    }

    func cancelCurrentReplacement() {}

    /// Called by `KeyboardMonitorHarness.press` for a physical keystroke that
    /// was NOT suppressed by a firing correction — i.e. what a real app
    /// would have rendered on its own, outside any backspace/retype
    /// transaction.
    func appendPhysicalChar(_ text: String) {
        screen += text
    }
}


/// Drives a real `KeyboardMonitor` with synthetic CGEvents. No XCTest, no
/// Accessibility API, no real focused app — `screen` is the only "display".
final class KeyboardMonitorHarness {
    let prefs = PreferencesService()
    let exceptions = ExceptionsService()
    let replacer: FakeTextReplacer
    let monitor: KeyboardMonitor
    private let inputSources: InputSourceManager
    /// Keystrokes `KeyboardMonitor.replaySink` captured while a replacement
    /// was in flight, waiting to be dispatched — the harness's stand-in for
    /// production replaying a real CGEvent back through the session tap.
    private var pendingReplays: [KeyEventSnapshot] = []

    var screen: String { replacer.screen }
    /// How many replacements the monitor actually attempted — the only way to
    /// assert "it left correct text alone" rather than "it happened to put the
    /// same characters back".
    var invocationCount: Int { replacer.invocationCount }

    /// Wave 2 (gamemode-spec-20260831.md) additive param — defaults to a
    /// fresh, real (`UserDefaults.standard`-backed) store, byte-for-byte the
    /// same as every pre-existing call site got implicitly before this
    /// param existed. Tests that need to control promotion (Bug A fix) pass
    /// their own isolated-suite instance instead.
    init(
        dictionary: WordDictionary, inputSources: InputSourceManager,
        secureInputDetector: SecureInputDetector = SecureInputDetector(secureCheck: { false }, axProbe: { false }),
        learnedWordsStore: LearnedWordsStore = LearnedWordsStore()
    ) {
        self.inputSources = inputSources
        let replacer = FakeTextReplacer(inputSources: inputSources)
        self.replacer = replacer
        let detector = LanguageDetector(
            dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs
        )
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let perApp = PerAppLayoutService(inputSourceManager: inputSources, prefsService: prefs)
        let snippetDefaults = UserDefaults(
            suiteName: AppIdentity.bundleIdentifier + ".tests.keyboard-monitor-snippets"
        )!
        let snippets = SnippetService(defaults: snippetDefaults)
        snippets.snippets = [:]
        monitor = KeyboardMonitor(
            languageDetector: detector, textReplacer: replacer,
            statsService: StatisticsService(), prefsService: prefs,
            exceptionsService: exceptions, yoficatorService: YoficatorService(),
            switchUndoManager: SwitchUndoManager(), perAppLayoutService: perApp,
            instantCorrectionAnalyzer: analyzer, snippetService: snippets,
            // The real IsSecureEventInputEnabled() is a GLOBAL OS flag, not
            // scoped to this test process — forcing it off here is what
            // makes this harness deterministic regardless of whatever's
            // actually focused on the machine running the tests. `axProbe`
            // is also forced off so this headless harness never dispatches a
            // real AX call to whatever happens to be focused on the machine
            // running the tests.
            secureInputDetector: secureInputDetector,
            learnedWordsStore: learnedWordsStore
        )
        // Mirrors `KeyEventSnapshot.makeEvent()`'s conditional marking
        // (plan 004): an `.ours` snapshot (a failed replacement's restored
        // trigger — see `PendingUserEventQueue.replaceFront`) keeps that
        // route when it round-trips through the real tap, so `dispatch`
        // below renders it without re-analyzing it. Everything else becomes
        // `.replayedUser`, exactly as before.
        monitor.replaySink = { [weak self] snapshot in
            self?.pendingReplays.append(snapshot.route == .ours ? snapshot : snapshot.asReplayed)
        }
        // Terminal-like: no AX inside this headless harness (a CLI test
        // binary has no focused element to read). A test that needs an
        // AX-backed run-resync sets its own provider instead.
        monitor.focusedTextProvider = { nil }
    }

    /// Renders `keycode`/`flags` as they'd appear on screen right now (the
    /// currently active layout) unless the tap suppressed them — shared by a
    /// fresh physical keydown and by draining a replayed one. Mirrors
    /// `eventTapCallback` (KeyboardMonitor.swift) branch for branch:
    /// `route == .ours` is passed straight through (rendered, never
    /// analyzed — the real tap does this for our own synthetic events);
    /// `queueIfReplacementActive` swallows a key that arrives mid-pause (the
    /// real app never sees it until it's replayed); everything else is
    /// handled + suppression-checked exactly as before.
    private func dispatch(_ snapshot: KeyEventSnapshot) {
        let rendered = inputSources.currentLayout.flatMap {
            inputSources.characterForKeycode(snapshot.keycode, layout: $0, flags: snapshot.flags)
        }
        if snapshot.route == .ours {
            if let rendered { replacer.appendPhysicalChar(rendered) }
            return
        }
        if monitor.queueIfReplacementActive(snapshot) { return }
        monitor.handle(snapshot)
        let suppressed = monitor.consumeSuppressCurrentEvent()
        if !suppressed, let rendered {
            replacer.appendPhysicalChar(rendered)
        }
    }

    /// Drains `pendingReplays` FIFO, dispatching each the same way a fresh
    /// keydown is dispatched — a replayed key may itself finish a
    /// replacement and queue MORE replays, so this loops until the list is
    /// empty, mirroring production (a replayed event only re-enters the tap
    /// after the current callback returns). Shared by `press` and
    /// `completePendingReplacement` — the two places a replacement can
    /// finish and hand back queued keystrokes.
    private func drainPendingReplays() {
        while !pendingReplays.isEmpty {
            dispatch(pendingReplays.removeFirst())
        }
    }

    /// Simulate one physical keydown. Mirrors `eventTapCallback`: run the
    /// same analysis `handle` does, then only render the character if the
    /// tap wouldn't have suppressed it — a firing correction suppresses the
    /// just-typed trigger letter and retypes it itself as part of its own
    /// payload (RC-1 in KeyboardMonitor.swift), so it must NOT also land on
    /// screen via the normal path.
    ///
    /// `autorepeat` (wave 2, gamemode-spec-20260831.md): sets the OS
    /// autorepeat field a real held-down key carries — additive, defaults
    /// to false so every pre-existing call renders exactly as before.
    func press(_ keycode: UInt16, flags: CGEventFlags = [], autorepeat: Bool = false) {
        dispatch(KeyEventSnapshot(type: .keyDown, keycode: keycode, flags: flags, autorepeat: autorepeat ? 1 : 0))
        drainPendingReplays()
    }

    func press(_ stroke: BufferedKeystroke) { press(stroke.keycode, flags: stroke.flags) }
    func type(_ strokes: [BufferedKeystroke]) { strokes.forEach { press($0) } }

    /// Completes a replacement the test put on hold via `replacer.mode =
    /// .deferred`, then drains any replay this produces — the harness's
    /// hand-crank for what happens automatically, later, in production.
    func completePendingReplacement(with result: TextReplacer.Result = .success) {
        replacer.completePending(with: result)
        drainPendingReplays()
    }
}


/// Snapshots the exact UserDefaults keys these tests flip, plus the Mac's
/// real active input source, and restores both unconditionally — same
/// hygiene as `PreferencesServiceTests` above, extended to the layout:
/// `KeyboardMonitor` reads `InputSourceManager.currentLayout` live from the
/// OS with no injection seam, so exercising real ru/en typing means actually
/// switching it for the duration of these tests.
private final class KeyboardMonitorTestEnvironment {
    private let inputSources: InputSourceManager
    private let originalLayoutID: String?
    private let defaults = UserDefaults.standard
    private let originalValues: [(key: String, value: Any?)]

    init(inputSources: InputSourceManager) {
        self.inputSources = inputSources
        originalLayoutID = inputSources.currentLayout?.id
        let prefix = AppIdentity.keyPrefix
        let keys = [
            prefix + "autoEnabled", prefix + "instantCorrection", prefix + "yoficator",
            prefix + "activeLayoutIDs", prefix + "wordExceptions", prefix + "appExceptions",
            prefix + "autoLearned",
        ]
        originalValues = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    func restore() {
        for (key, value) in originalValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let originalLayoutID, let layout = inputSources.layout(withID: originalLayoutID) {
            inputSources.switchTo(layout)
        }
    }
}


enum KeyboardMonitorIntegrationTests {
    static func run() {
        TestRunner.section("KeyboardMonitor integration — headless typed-sequence → screen (no GUI)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the KeyboardMonitor integration harness")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        func harness(autoSwitch: Bool) -> KeyboardMonitorHarness {
            let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
            h.prefs.isAutoSwitchEnabled = autoSwitch
            h.prefs.isInstantCorrectionEnabled = true
            h.prefs.isYoficatorEnabled = false
            h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
            h.exceptions.appExceptions = []
            h.exceptions.wordExceptions = []
            h.exceptions.autoLearned = [:]
            return h
        }

        // --- "/exit" — the reported ".yexit" defect, task minimum -----------
        // Double Shift with auto-switch OFF: this is exactly how the live bug
        // was hit — Terminal.app is in ExceptionsService's default app-
        // exception list, so manual Double Shift is the ONLY correction path
        // available there, never the automatic ones.
        TestRunner.section("Double Shift folds a leading symbol — \"/exit\" (live \".yexit\" defect)")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(44) // "/" → "." under ru
            if let exit = InstantCorrectionFixtures.keystrokes(for: "exit", reverse: enReverse) {
                h.type(exit)
                TestRunner.assertEqual(
                    h.screen, ".учше",
                    "sanity: on-screen text before Double Shift matches the live debug.log verbatim"
                )
                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
                TestRunner.assertEqual(
                    h.screen, "/exit",
                    "fix: leading '/' converts together with the word — no dropped symbol, no extra character"
                )
            } else {
                TestRunner.assertTrue(false, "'exit': EN fixture can type every character")
            }
        }

        // --- symbol keys that are letters in Russian -------------------------
        // 39.6% of Russian words >=3 letters contain at least one of б ю х ж ё
        // э ъ, which live on `,` `.` `[` `;` `` ` `` `'` `]`. Those keys used to
        // close the word on the spot, so the head got corrected alone and the
        // tail started a new word: "до так;е" (owner, 05.08).
        TestRunner.section("Symbol keys stay inside the word — \"также\", \"колбаса\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let takzhe = InstantCorrectionFixtures.keystrokes(for: "также", reverse: ruReverse) {
                h.type(takzhe)
                h.press(49) // space — the real boundary, where the decision belongs
                TestRunner.assertEqual(
                    h.screen, "также ",
                    "fix: the whole word converts — red was \"так;е \", corrected at the ';' key"
                )
            } else {
                TestRunner.assertTrue(false, "'также': RU fixture can type every character")
            }
        }
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let kolbasa = InstantCorrectionFixtures.keystrokes(for: "колбаса", reverse: ruReverse) {
                h.type(kolbasa)
                h.press(49)
                TestRunner.assertEqual(
                    h.screen, "колбаса ",
                    "fix: 'б' (the ',' key) no longer splits the word after the dictionary word 'кол'"
                )
            } else {
                TestRunner.assertTrue(false, "'колбаса': RU fixture can type every character")
            }
        }

        // --- English must not become Russian ---------------------------------
        // The above is only safe because the detector scores the LETTER CORE and
        // reads a trailing ambiguous key both ways. Without that, "key." renders
        // as the real Russian word "луню" and wins unopposed — and with the old
        // contextBias of 15 (larger than the 10-point collision gap) a preceding
        // Russian word was enough to open the gate on its own.
        TestRunner.section("English survives the symbol run — \"key.\", \"bye.\", \"next.\"")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            // Prime the context with a Russian word, the worst case for English.
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) {
                h.type(privet)
                h.press(49)
            }
            inputSources.switchTo(enLayout)
            let h2 = harness(autoSwitch: true)
            for word in ["key", "bye", "next"] {
                if let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: enReverse) {
                    h2.type(strokes)
                    h2.press(47) // "." — a letter (ю) in Russian
                    h2.press(49)
                } else {
                    TestRunner.assertTrue(false, "'\(word)': EN fixture can type every character")
                }
            }
            TestRunner.assertEqual(
                h2.screen, "key. bye. next. ",
                "correctly typed English with trailing punctuation is left alone"
            )
            TestRunner.assertEqual(
                h2.invocationCount, 0,
                "not a single replacement was attempted on correct English"
            )
        }

        // --- ambiguousKeyRecent unblocks mid-word once 1 plain letter follows
        // (narrowed from 2 on 21.08.2026 — see the property's doc comment)
        // "работа" = "hf,jnf" on EN keys — the ambiguous ',' ('б') sits at
        // index 3. Instant correction stays gated at index 3 (the ambiguous
        // key IS the last keystroke) and is free to fire again at index 4
        // ("hf,j" = "рабо", a confident dictionary prefix) — i.e. before the
        // word is even finished, let alone before a word boundary. A sticky
        // whole-run flag (the old `runHasAmbiguousKey`) would keep this
        // blocked all the way to the end of the word instead.
        TestRunner.section("Instant correction unblocks past an ambiguous key once 1 letter follows — \"работа\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let rabota = InstantCorrectionFixtures.keystrokes(for: "работа", reverse: ruReverse) {
                for stroke in rabota.dropLast() { h.press(stroke) } // "hf,jn" — everything but the last "f"
                TestRunner.assertEqual(
                    h.invocationCount, 1,
                    "instant correction already fired mid-word, before the final letter and before any space"
                )
                TestRunner.assertEqual(
                    h.screen, "работ",
                    "on-screen text is the corrected Russian prefix — fixed before the word was even finished"
                )
                h.press(rabota.last!) // the trailing "f" ("а") — types normally on the now-switched layout
                TestRunner.assertEqual(
                    h.invocationCount, 1,
                    "the word boundary/gate path does not fire a second correction on the same word"
                )
                TestRunner.assertEqual(h.screen, "работа", "the rest of the word completes correctly on the new layout")
            } else {
                TestRunner.assertTrue(false, "'работа': ru fixture can type every character")
            }
        }

        // --- ambiguousKeyRecent still blocks while the key is in the last 2 -
        // "key." — the "." (kc47) is a letter in Russian ("ю") and joins the
        // word buffer as its own defense (see the comment above), landing
        // right at the last keystroke. Instant correction must NOT misread
        // it as the real Russian word "луню" while it's still that recent —
        // the full word-boundary scorer (which reads the trailing key both
        // ways) is what safely resolves "key." as English, not the looser
        // instant path.
        TestRunner.section("Instant correction stays gated with the ambiguous key in the last 2 keystrokes — \"key.\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            if let key = InstantCorrectionFixtures.keystrokes(for: "key", reverse: enReverse) {
                h.type(key)
                h.press(47) // "." — a letter (ю) in Russian; joins the buffer, not a boundary
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "instant correction stays blocked while '.' is still within the last 2 keystrokes"
                )
                TestRunner.assertEqual(h.screen, "key.", "on-screen text is exactly what was typed, untouched so far")
            } else {
                TestRunner.assertTrue(false, "'key': EN fixture can type every character")
            }
        }

        // --- Trailing trigger renders on the TARGET layout, not the source --
        // Shift+kc44 is '?' on QWERTY but ',' on ЙЦУКЕН (same physical key);
        // Shift+kc26 is '&' on QWERTY but '?' on ЙЦУКЕН. The trigger that
        // closes an auto-corrected word used to render on the layout it was
        // PRESSED on (before the switch) instead of the one the word lands
        // in — "Да" + Shift+kc44 in en printed "Да?" instead of "Да,".
        // Instant correction is switched off in all three cases below: it
        // fires MID-WORD and would flip the layout before the trigger key is
        // even pressed, masking the bug this test targets — the trigger
        // that closes the word at the BOUNDARY (processCurrentWord).
        TestRunner.section("Trailing trigger converts with the word — \"Да,\" not \"Да?\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let privet = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(privet)
                h.press(44, flags: .maskShift) // '?' on QWERTY, ',' on ЙЦУКЕН
                TestRunner.assertEqual(
                    h.screen, "привет,",
                    "fix: trailing renders on the TARGET (ru) layout — was \"привет?\""
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            }
        }
        // Mirror direction: ru → en.
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let what = InstantCorrectionFixtures.keystrokes(for: "what", reverse: enReverse) {
                h.type(what)
                h.press(44, flags: .maskShift)
                TestRunner.assertEqual(
                    h.screen, "what?",
                    "fix: trailing renders on the TARGET (en) layout — was \"what,\""
                )
            } else {
                TestRunner.assertTrue(false, "'what': EN fixture can type every character")
            }
        }
        // Second trigger key on the same physical row, same direction as the
        // first case (en → ru) — the bug's other reported instance ("Что&"
        // instead of "Что?").
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false
            if let dela = InstantCorrectionFixtures.keystrokes(for: "дела", reverse: ruReverse) {
                h.type(dela)
                h.press(26, flags: .maskShift) // '&' on QWERTY, '?' on ЙЦУКЕН
                TestRunner.assertEqual(
                    h.screen, "дела?",
                    "fix: Shift+kc26 also renders on the TARGET (ru) layout — was \"дела&\""
                )
            } else {
                TestRunner.assertTrue(false, "'дела': RU fixture can type every character")
            }
        }

        // --- lone "b" → "и" — the 05.08.2026 report ------------------------
        // Owner pressed Double Shift five times on a single latin "b" in
        // Ghostty and nothing happened (log 07:49:54-57, five consecutive
        // "no selection/buffer/history/caret word"). Cause: every path had a
        // 2-character floor. Single letters are ordinary Russian words.
        TestRunner.section("Double Shift converts a SINGLE-letter word — lone \"b\" → \"и\"")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(11) // "b" under en → "и" under ru
            TestRunner.assertEqual(h.screen, "b", "sanity: a lone latin letter is on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reports a conversion for a one-letter word"
            )
            TestRunner.assertEqual(
                h.screen, "и",
                "fix: the single letter converts instead of being silently skipped"
            )
        }

        // A one-letter LIVE buffer must win over an older history slot —
        // otherwise the fix above would convert the previous word instead of
        // the letter the user is actually looking at.
        // The block above ends with the layout switched to ru (that is what a
        // conversion does) — reset it, or "hello" gets typed as "руддщ".
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) {
                h.type(hello)
                h.press(49) // space — "hello" moves into the history slot
                h.press(11) // "b" — a new, one-character live buffer
                TestRunner.assertEqual(h.screen, "hello b", "sanity: both words are on screen before the swap")
                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "conversion happens")
                TestRunner.assertEqual(
                    h.screen, "hello и",
                    "the live one-letter buffer is converted, the history word is left alone"
                )
            } else {
                TestRunner.assertTrue(false, "'hello': EN fixture can type every character")
            }
        }

        // A one-letter word that has already been closed by a space must stay
        // reachable: the history slot used to carry a 2-character floor, so
        // "b" converted while "b " did not — the same lone-"b" report one
        // keystroke later (log 13.08.2026, four "no selection/buffer/history/
        // caret word" skips in Ghostty).
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            h.press(11) // "b"
            h.press(49) // space — the word moves into the history slot
            TestRunner.assertEqual(h.screen, "b ", "sanity: the closed one-letter word is on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reaches a one-letter word through the history slot"
            )
            TestRunner.assertEqual(
                h.screen, "и ",
                "fix: the closed single letter converts, its trailing space is preserved"
            )
        }

        // A lone SYMBOL is convertible too — the run path used to require two
        // characters, so "ю" typed where "." was meant had no path at all:
        // auto-correction never touches a single character, and the scored
        // path has no word to score.
        inputSources.switchTo(enLayout)
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(47) // "." in Latin, the LETTER "ю" in Cyrillic
            TestRunner.assertEqual(h.screen, "ю", "sanity: a lone Cyrillic letter-symbol on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift converts a one-character run"
            )
            TestRunner.assertEqual(h.screen, ".", "fix: the single symbol converts key-for-key")
        }

        // The same for a key that is punctuation in BOTH alphabets and so
        // never enters the letter buffer at all — keycode 44 is "/" in Latin
        // and "." in Cyrillic. Only the run path can reach it, and that path
        // used to require two characters.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(44) // "/" in Latin, "." in Cyrillic
            TestRunner.assertEqual(h.screen, ".", "sanity: a lone punctuation key on screen")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift converts a one-character run of pure punctuation"
            )
            TestRunner.assertEqual(h.screen, "/", "fix: «.» typed where «/» was meant is reachable")
        }

        // --- "7ю6с" → "7.6s" — a run the dictionary cannot judge -------------
        // Owner typed "7.6s" with the Russian layout active, got "7ю6с", and
        // pressed Double Shift three times with nothing happening at all (log
        // 09:07:51–09:08:08, every press "no selection/buffer/history/caret
        // word"). The digits slice the run into three fragments — "ю", "с" —
        // none of which is a word, so the scored path had nothing to work
        // with. An explicit gesture is not a request for a judgement.
        TestRunner.section("Double Shift converts a whole run with digits — «7ю6с» → «7.6c»")
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(26) // 7
            h.press(47) // "." in en, "ю" in ru
            h.press(22) // 6
            h.press(8)  // "c" in en, "с" in ru
            TestRunner.assertEqual(h.screen, "7ю6с", "sanity: the run is on screen in the wrong alphabet")
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift reports a conversion for a digits-and-letters run"
            )
            TestRunner.assertEqual(
                h.screen, "7.6c",
                "the WHOLE run converts key-for-key, digits kept, nothing left behind"
            )
        }

        // --- lone "b" + space auto-corrects, but "rm -f" does NOT -------------
        // Owner: typed "b", pressed space, expected "и", got nothing — the
        // floor was 3 letters, so the single-letter Russian words (и в с к я а
        // о у) were unreachable for automatic correction. The pair below is
        // the whole justification for lowering it: the same change would turn
        // "rm -f" into "rm -а" if a leading symbol didn't block it, because
        // "а" is a genuine Russian word and wins the scoring fairly.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Auto-correction reaches one-letter words — «b » → «и », but «-f » stays")
            inputSources.switchTo(enLayout)
            let h = harness(autoSwitch: true)
            h.press(11) // "b" on en
            h.press(49) // space — the word boundary
            TestRunner.assertEqual(h.screen, "и ", "a lone «b» becomes the Russian word «и»")

            inputSources.switchTo(enLayout)
            let flags = harness(autoSwitch: true)
            flags.press(27) // "-"
            flags.press(3)  // "f"
            flags.press(49) // space
            TestRunner.assertEqual(
                flags.screen, "-f ",
                "a flag is left alone — the leading symbol keeps the short-word path shut"
            )
            _ = ruLayout
        }

        // --- "ы1" → "s1" — one letter plus a digit ----------------------------
        // Owner, 20:01:50. Auto-correction can't help here (a single letter is
        // far under the 3-letter floor), so Double Shift is the ONLY way to fix
        // it — and it answered "no selection/buffer/history/caret word".
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Double Shift on «ы1» — one letter and a digit")
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            h.press(1)  // "s" in en, "ы" in ru
            h.press(18) // "1"
            TestRunner.assertEqual(h.screen, "ы1", "sanity: letter plus digit on screen")
            TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
            TestRunner.assertEqual(h.screen, "s1", "the pair converts — the digit stays, the letter moves")
        }

        // --- "./exit" typed on RU — the leading "." is a LETTER there ---------
        // Owner typed "./exit" with the Russian layout active and got
        // "./exit" back with a stray dot in front (log 18:43:06,
        // "doubleShift via run len=5" — five characters counted where six
        // were typed). Keycode 47 is "." in Latin but the LETTER "ю" in
        // Cyrillic, so the run starts with a letter and continues through a
        // symbol; nothing about that may drop a keystroke.
        do {
            guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
                TestRunner.skip("RU layout required")
                return
            }
            TestRunner.section("Double Shift on «ю.учше» typed for «./exit» — nothing dropped")
            inputSources.switchTo(ruLayout)
            let h = harness(autoSwitch: false)
            for code in [UInt16(47), 44, 14, 7, 34, 17] { h.press(code) }
            TestRunner.assertEqual(
                h.screen, "ю.учше", "sanity: six keystrokes, six characters on screen"
            )
            TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion")
            TestRunner.assertEqual(
                h.screen, "./exit",
                "all six convert — no character left stranded in front"
            )
        }

        // --- "на 300$" — history must not outlive the caret ------------------
        // Double Shift's history fallback rewrites text AT THE CARET. Owner
        // typed "на" + space + "300$" and pressed Double Shift: the stale "на"
        // was converted and retyped at the caret, eating the digits and
        // producing "на 30yf" (log 08:26:04, "doubleShift via history:
        // ru→en len=2" with four leading symbols already typed after it).
        TestRunner.section("Digits kill the history slot — the \"на 300$\" corruption")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            if let na = InstantCorrectionFixtures.keystrokes(for: "на", reverse: ruReverse) {
                h.type(na)
                h.press(49)  // space — "на" moves into the history slot
                h.press(29)  // "3"
                h.press(26)  // "0"
                h.press(26)  // "0"
                let before = h.screen
                TestRunner.assertTrue(
                    !h.monitor.swapLastWordInBuffer(),
                    "Double Shift refuses: the history word is no longer next to the caret"
                )
                TestRunner.assertEqual(
                    h.screen, before,
                    "fix: nothing is rewritten — the digits stay intact instead of being eaten"
                )
            } else {
                TestRunner.assertTrue(false, "'на': RU fixture can type every character")
            }
        }

        // --- "$GRAF", "/model" — same fold-in via the automatic paths -------
        TestRunner.section("Auto-correct folds a leading symbol — \"/model\", \"$GRAF\"")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true)
            h.press(44) // "/"
            if let model = InstantCorrectionFixtures.keystrokes(for: "model", reverse: enReverse) {
                h.type(model)
                // Trailing space flushes the boundary path if instant didn't
                // already fire — since 19.08.2026 "model" is exactly that
                // case: its own ru reading is CLEAN (junk-gate), so instant
                // now defers here (same trade-off InstantCorrectionAnalyzerTests'
                // "руддщ" case documents) and the boundary path is what
                // actually folds the leading "/" in this run.
                h.press(49)
                TestRunner.assertEqual(
                    h.screen, "/model ",
                    "'/model' converts with the leading '/' intact (Ghostty 03.08.2026 regression, integration level)"
                )
            } else {
                TestRunner.assertTrue(false, "'model': EN fixture can type every character")
            }
        }
        inputSources.switchTo(ruLayout)
        do {
            // Named case is "$GRAF" (CLAUDE.md citation); reproduced here as
            // "$HELLO" — "graf" itself is too short/uncommon a word for the
            // dictionary/spellchecker to confidently score at either the
            // instant or the boundary threshold (same substitution
            // LeadingSymbolRunGuardTests already documents above for the
            // exact same citation), which would make this a scoring-
            // calibration test rather than a leading-symbol-fold-in test.
            // "hello" is one of the suite's proven golden words.
            let h = harness(autoSwitch: true)
            h.press(21, flags: .maskShift) // shift+4 → ";" under ru
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) {
                for stroke in hello { h.press(stroke.keycode, flags: .maskShift) } // HELLO, all-caps
                h.press(49) // trailing space — flushes the boundary path if instant didn't already fire
                TestRunner.assertEqual(
                    h.screen, "$HELLO ",
                    "'$HELLO' converts with the leading '$' intact ('$GRAF'-style leading-symbol citation)"
                )
            } else {
                TestRunner.assertTrue(false, "'hello': EN fixture can type every character")
            }
        }

        // --- «марже»-class direction/drift bug, integration level -----------
        // Named regression is «марже» (CLAUDE.md); reproduced here with
        // «привет» instead — «марже» contains "ж", which physically sits on
        // the ";" key, itself a real EN word-boundary trigger
        // (InputBuffer.cyrillicOnlyLetterCodes) — typing it while EN is
        // active would legitimately split the buffer mid-word regardless of
        // this bug, which is a separate, pre-existing interaction outside
        // this fix's scope (documented in the final report). «привет» avoids
        // that letter entirely while exercising the exact same primitive
        // (`swapTarget` resolving direction from the CAPTURED typed layout,
        // never "whatever's active now") that `MarzheDoubleShiftRegressionTests`
        // already pins at the unit level.
        TestRunner.section("Double Shift history survives an active-layout drift — «марже»-class bug, integration level")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: false)
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) {
                h.type(privet)
                h.press(49) // space — completes the word into history, buffer clears
                TestRunner.assertTrue(
                    !h.screen.contains("привет"),
                    "sanity: EN-active typing renders «привет»'s physical keys as Latin garbage"
                )

                // Active layout drifts to ru BETWEEN word completion and the
                // Double Shift press — direction must resolve from the
                // CAPTURED typed layout (en), never "whatever's active now".
                inputSources.switchTo(ruLayout)

                TestRunner.assertTrue(
                    h.monitor.swapLastWordInBuffer(), "Double Shift reports a conversion from history"
                )
                TestRunner.assertEqual(
                    h.screen, "привет ",
                    "fix: direction resolves from the layout the word was TYPED on, not the drifted active layout"
                )
            } else {
                TestRunner.assertTrue(false, "«привет»: ru fixture can type every character")
            }
        }

        // --- Toggle: two presses return the original, a third converts again
        TestRunner.section("Double Shift toggle — two presses return the original, a third converts again")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: false)
            if let helloAsRu = InstantCorrectionFixtures.keystrokes(for: "руддщ", reverse: ruReverse) {
                h.type(helloAsRu)
                TestRunner.assertEqual(h.screen, "руддщ", "sanity: on-screen text before any Double Shift press")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "1st press reports a conversion")
                TestRunner.assertEqual(h.screen, "hello", "1st press: ru→en gives 'hello'")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "2nd press reports a conversion")
                TestRunner.assertEqual(h.screen, "руддщ", "2nd press: converts BACK to the original on-screen text")

                TestRunner.assertTrue(h.monitor.swapLastWordInBuffer(), "3rd press reports a conversion")
                TestRunner.assertEqual(h.screen, "hello", "3rd press: converts again — one press per result, never stuck")
            } else {
                TestRunner.assertTrue(false, "'руддщ': ru fixture can type every character")
            }
        }

        // --- Live typing: spaces not eaten, words not glued -----------------
        TestRunner.section("Live typing — spaces are not eaten, words are not glued (\"и самое главное\")")
        inputSources.switchTo(ruLayout)
        do {
            let h = harness(autoSwitch: true) // correctly-typed ru words — must never fire
            let phrase = "и самое главное"
            var typedOK = true
            for ch in phrase {
                if ch == " " {
                    h.press(49)
                } else if let kc = ruReverse[ch] {
                    h.press(kc)
                } else {
                    typedOK = false
                }
            }
            TestRunner.assertTrue(typedOK, "sanity: every character of the phrase has a ru fixture mapping")
            TestRunner.assertEqual(
                h.screen, phrase, "spaces preserved, words not glued, no false-positive correction mid-phrase"
            )
            TestRunner.assertEqual(h.replacer.invocationCount, 0, "no correction ever fired on correctly-typed text")
        }

        // --- FIX A (13.08.2026): Cmd+Shift+V must not leave a stale buffer --
        // `KeyboardMonitorHarness` never wires `hotkeyManager` (it exercises
        // `handleEvent`'s own analysis, not HotkeyManager's live TIS/AX
        // calls), so `started` is always false here — this exercises the
        // "paste never actually fired" arm of the fix, the one FIX A's own
        // comment calls out as easy to forget since the paste itself doesn't
        // live in it. Before the fix, `buffer`/`runKeystrokes` from typing
        // "ghbdtn" survived the Cmd+Shift+V branch untouched, and the space
        // right after fired a boundary correction on that stale buffer.
        TestRunner.section("Cmd+Option+Shift+V invalidates the stale word buffer (FIX A)")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false // isolate the boundary-correction path
            if let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(ghbdtn)
                h.press(9, flags: [.maskCommand, .maskShift, .maskAlternate]) // Cmd+Option+Shift+V
                h.press(49) // space — word boundary
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "a stale buffer from before Cmd+Option+Shift+V does not fire a correction after the paste"
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': en fixture can type every character")
            }
        }

        // --- NEW (15.08.2026): bare Cmd+Shift+V (no Option) must now pass --
        // through untouched — PasteNow (the owner's clipboard manager) opens
        // on the SAME shortcut (carbonKeyCode 9, modifiers 768) and our tap
        // was swallowing it, killing PasteNow. Paste-without-formatting moved
        // to Cmd+Option+Shift+V (macOS's own "Paste and Match Style" combo);
        // plain Cmd+Shift+V must not even enter the paste-no-format branch —
        // it falls straight through to the ordinary modifier-shortcut path
        // (any Cmd/Ctrl/Option combo invalidates context there already).
        //
        // `consumeSuppressCurrentEvent()`/`invocationCount` can't tell the two
        // branches apart here: neither ever sets the internal suppress flag
        // for this key (the REAL swallow happens in `handlesShortcut`, which
        // is `fileprivate` and only reachable from the real CGEventTap
        // callback — the structural check above already pins that), and
        // `hotkeyManager` is never wired in this harness, so a "started"
        // paste never reaches the replacer either way. The one thing that
        // DOES differ observably is whether `handleEvent`'s branch itself
        // ran at all — it logs unconditionally on every pass — so the debug
        // log is the actual falsifiable signal for "which branch executed".
        TestRunner.section("Cmd+Shift+V without Option never enters the paste-no-format branch")
        inputSources.switchTo(enLayout)
        do {
            let h = harness(autoSwitch: true)
            h.prefs.isInstantCorrectionEnabled = false // isolate the boundary-correction path
            if let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) {
                h.type(ghbdtn)
                DebugLog.shared.waitForPendingWrites()
                let before = DebugLog.shared.currentContents
                h.press(9, flags: [.maskCommand, .maskShift]) // no .maskAlternate
                DebugLog.shared.waitForPendingWrites()
                let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
                TestRunner.assertTrue(
                    !newLines.contains("pasteNoFormat:"),
                    "bare Cmd+Shift+V (no Option) never enters the paste-no-format branch at all"
                )
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "bare Cmd+Shift+V never starts a paste-no-format replacement — Option is required now"
                )
                h.press(49) // space — would fire a boundary correction if the stale buffer had survived
                TestRunner.assertEqual(
                    h.invocationCount, 0,
                    "the modifier-shortcut path still invalidated the stale 'ghbdtn' buffer, so the space corrects nothing"
                )
            } else {
                TestRunner.assertTrue(false, "'ghbdtn': en fixture can type every character")
            }
        }

        // --- Guards: shell/code punctuation and correctly-typed words -------
        TestRunner.section("Guards — correctly-typed text and shell/code punctuation never trigger a correction")

        func assertNoCorrection(
            _ label: String, layout: KeyboardLayout, expectedScreen: String,
            _ typeIt: (KeyboardMonitorHarness) -> Void
        ) {
            inputSources.switchTo(layout)
            let h = harness(autoSwitch: true)
            typeIt(h)
            TestRunner.assertEqual(
                h.replacer.invocationCount, 0, "\(label): never triggers a backspace/retype transaction"
            )
            TestRunner.assertEqual(h.screen, expectedScreen, "\(label): on-screen text is exactly what was typed")
        }

        assertNoCorrection("#tag", layout: enLayout, expectedScreen: "#tag ") { h in
            h.press(20, flags: .maskShift) // "#"
            if let tag = InstantCorrectionFixtures.keystrokes(for: "tag", reverse: enReverse) { h.type(tag) }
            h.press(49)
        }
        assertNoCorrection("@name", layout: enLayout, expectedScreen: "@name ") { h in
            h.press(19, flags: .maskShift) // "@"
            if let name = InstantCorrectionFixtures.keystrokes(for: "name", reverse: enReverse) { h.type(name) }
            h.press(49)
        }
        assertNoCorrection("./script", layout: enLayout, expectedScreen: "./script ") { h in
            h.press(47) // "." — EN word boundary (punctuation), not a leading symbol; still safe
            h.press(44) // "/"
            if let script = InstantCorrectionFixtures.keystrokes(for: "script", reverse: enReverse) { h.type(script) }
            h.press(49)
        }
        assertNoCorrection("$PATH", layout: enLayout, expectedScreen: "$PATH ") { h in
            h.press(21, flags: .maskShift) // "$"
            if let path = InstantCorrectionFixtures.keystrokes(for: "path", reverse: enReverse) {
                for stroke in path { h.press(stroke.keycode, flags: .maskShift) } // PATH, all-caps
            }
            h.press(49)
        }
        assertNoCorrection("git commit -m", layout: enLayout, expectedScreen: "git commit -m") { h in
            if let git = InstantCorrectionFixtures.keystrokes(for: "git", reverse: enReverse) { h.type(git) }
            h.press(49)
            if let commit = InstantCorrectionFixtures.keystrokes(for: "commit", reverse: enReverse) { h.type(commit) }
            h.press(49)
            h.press(27) // "-"
            if let mKey = enReverse["m"] { h.press(mKey) }
        }
        assertNoCorrection("100$", layout: enLayout, expectedScreen: "100$") { h in
            h.press(18) // "1"
            h.press(29) // "0"
            h.press(29) // "0"
            h.press(21, flags: .maskShift) // "$"
        }
        assertNoCorrection("№1", layout: ruLayout, expectedScreen: "№1") { h in
            h.press(20, flags: .maskShift) // "№" under ru
            h.press(18) // "1"
        }
        assertNoCorrection("correctly-typed EN word", layout: enLayout, expectedScreen: "hello ") { h in
            if let hello = InstantCorrectionFixtures.keystrokes(for: "hello", reverse: enReverse) { h.type(hello) }
            h.press(49)
        }
        assertNoCorrection("correctly-typed RU word", layout: ruLayout, expectedScreen: "привет ") { h in
            if let privet = InstantCorrectionFixtures.keystrokes(for: "привет", reverse: ruReverse) { h.type(privet) }
            h.press(49)
        }
    }
}


// MARK: - Game mode (gamemode-spec-20260831.md, wave 2): heldKeys + sanity cap
// gates. Both are independent of GameModeState's own bundleID tracking — the
// gate itself lives on `wordAutorepeatCount`/keystroke count inside
// KeyboardMonitor, `gameMode.note(...)` is only a side effect these tests
// don't need to observe (the harness's default `.shared` no-ops it safely,
// same as every OTHER existing test using this harness — `activeAppBundleID`
// stays nil under `--test`, per `KeyboardMonitor.init`'s own doc comment).
enum HeldKeysGameModeGateTests {
    static func run() {
        TestRunner.section("Game mode — ≥3 autorepeat keystrokes in a word silence both correction paths")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the held-keys gate fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        func harness() -> KeyboardMonitorHarness {
            // Each call must start every block in the same, known layout —
            // `inputSources` is shared across this suite's `do` blocks, and
            // an earlier block's correction leaves it switched (simulated
            // layout persists on the instance, see InputSourceManager).
            inputSources.switchTo(enLayout)
            let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
            h.prefs.isAutoSwitchEnabled = true
            h.prefs.isInstantCorrectionEnabled = true
            h.prefs.isYoficatorEnabled = false
            h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
            h.exceptions.appExceptions = []
            h.exceptions.wordExceptions = []
            h.exceptions.autoLearned = [:]
            return h
        }

        // "ghbdtn" (en keys) → привет — golden case, fires instantly by the
        // last keystroke (length 6) per InstantCorrectionAnalyzerTests above.
        inputSources.switchTo(enLayout)
        guard let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            return
        }

        do {
            let h = harness()
            for stroke in ghbdtn.prefix(3) { h.press(stroke.keycode, flags: stroke.flags, autorepeat: true) }
            for stroke in ghbdtn.dropFirst(3) { h.press(stroke.keycode, flags: stroke.flags) }
            TestRunner.assertEqual(
                h.invocationCount, 0,
                "instant correction never fires once 3 autorepeat keystrokes have landed in this word"
                    + " (golden case \"ghbdtn\" would otherwise fire mid-word)"
            )
        }

        // Control: only 2 autorepeats — below the ≥3 threshold — must not
        // block the ordinary golden-case fire.
        do {
            let h = harness()
            for stroke in ghbdtn.prefix(2) { h.press(stroke.keycode, flags: stroke.flags, autorepeat: true) }
            for stroke in ghbdtn.dropFirst(2) { h.press(stroke.keycode, flags: stroke.flags) }
            TestRunner.assertEqual(
                h.invocationCount, 1,
                "control: 2 autorepeat keystrokes (below the ≥3 threshold) do not block instant correction"
            )
        }

        // Boundary path: instant OFF, same ≥3-autorepeat word, then a space.
        do {
            let h = harness()
            h.prefs.isInstantCorrectionEnabled = false
            for stroke in ghbdtn.prefix(3) { h.press(stroke.keycode, flags: stroke.flags, autorepeat: true) }
            for stroke in ghbdtn.dropFirst(3) { h.press(stroke.keycode, flags: stroke.flags) }
            h.press(49) // space
            TestRunner.assertEqual(h.invocationCount, 0, "boundary correction also skips a word with ≥3 autorepeats")
            TestRunner.assertEqual(h.screen, "ghbdtn ", "the held-key word is left exactly as typed")
        }

        // Control: same word, boundary path, WITHOUT autorepeats — corrects normally.
        do {
            let h = harness()
            h.prefs.isInstantCorrectionEnabled = false
            h.type(ghbdtn)
            h.press(49) // space
            TestRunner.assertEqual(h.invocationCount, 1, "control: without autorepeats the boundary path still corrects")
            TestRunner.assertEqual(h.screen, "привет ", "control: corrected to the real word")
        }
    }
}


enum SanityCapBoundaryGuardTests {
    static func run() {
        TestRunner.section("Sanity cap — a run longer than 20 keystrokes never reaches the boundary detector either")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the sanity-cap fixture")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        inputSources.switchTo(enLayout)
        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
        h.prefs.isAutoSwitchEnabled = true
        h.prefs.isInstantCorrectionEnabled = false // isolate the boundary path
        h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]

        let overLength = InstantCorrectionAnalyzer.maxLength + 1
        guard let over = InstantCorrectionFixtures.keystrokes(
            for: String(repeating: "a", count: overLength), reverse: enReverse
        ) else {
            TestRunner.assertTrue(false, "\(overLength)×'a': EN fixture can type every character")
            return
        }
        h.type(over)
        h.press(49) // space
        TestRunner.assertEqual(
            h.invocationCount, 0,
            "a \(overLength)-keystroke run never reaches the boundary detector — the cap returns first"
        )
    }
}


// MARK: - Bug fixes (bugfixes-diag-20260831.md, wave 2)

enum BackspaceResetsInstantGateTests {
    static func run() {
        TestRunner.section("Bug B fix — backspace resets instantCorrectionGate so the boundary path re-evaluates")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the 'работа' fixture")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        func harness() -> KeyboardMonitorHarness {
            // Each call must start every block in the same, known layout —
            // `inputSources` is shared across this suite's `do` blocks, and
            // an earlier block's correction leaves it switched (simulated
            // layout persists on the instance, see InputSourceManager).
            inputSources.switchTo(enLayout)
            let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
            h.prefs.isAutoSwitchEnabled = true
            h.prefs.isInstantCorrectionEnabled = true
            h.prefs.isYoficatorEnabled = false
            h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
            h.exceptions.appExceptions = []
            h.exceptions.wordExceptions = []
            h.exceptions.autoLearned = [:]
            return h
        }

        inputSources.switchTo(enLayout)
        guard let rabota = InstantCorrectionFixtures.keystrokes(for: "работа", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'работа': ru fixture can type every character")
            return
        }

        // (a) instant fires mid-word ("hf,jn"), THEN a backspace, THEN a
        // couple more letters, THEN the word boundary — the fix must let the
        // boundary path actually run (not silently skip it).
        do {
            let h = harness()
            for stroke in rabota.dropLast() { h.press(stroke) } // "hf,jn" — fires instant
            TestRunner.assertEqual(h.invocationCount, 1, "setup: instant correction fired mid-word")

            h.press(51) // backspace (InputBuffer.isDeleteKey)
            DebugLog.shared.waitForPendingWrites()
            let before = DebugLog.shared.currentContents
            h.press(rabota.last!) // retype a letter after the backspace
            h.press(49) // space — word boundary
            DebugLog.shared.waitForPendingWrites()
            let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
            TestRunner.assertTrue(
                !newLines.contains("skip boundary correction: already instant-corrected"),
                "the boundary path is NOT silently skipped after a mid-word backspace (Bug B)"
            )
        }

        // (b) control: WITHOUT a backspace, the boundary path still skips
        // the just-instant-corrected word — unchanged existing behavior.
        do {
            let h = harness()
            h.type(rabota) // fires instant, then the last letter types normally
            DebugLog.shared.waitForPendingWrites()
            let before = DebugLog.shared.currentContents
            h.press(49) // space — no backspace in between
            DebugLog.shared.waitForPendingWrites()
            let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
            TestRunner.assertTrue(
                newLines.contains("skip boundary correction: already instant-corrected"),
                "control: without a backspace, the boundary path still skips the just-instant-corrected word"
            )
        }
    }
}


enum DoubleShiftInapplicableLogTests {
    static func run() {
        TestRunner.section("Bug A fix — 'learned: inapplicable' checks the OWN reading in sourceLang, not the target")

        let inputSources = InputSourceManager()
        guard let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }),
              inputSources.supportedLayouts.contains(where: { $0.isEnglish }) else {
            TestRunner.skip("EN + RU layouts are required")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        // Types `word` twice (fresh each time — never toggling the SAME
        // correction back, which `CorrectionFeedbackTracker` would classify
        // as `.toggleOfManualFix` instead of a second `.manualFix`) via
        // Double Shift on an isolated `LearnedWordsStore`, so the SECOND
        // occurrence is the promoting one, and reports whether
        // "learned: inapplicable" was logged by it.
        func promotedInapplicable(word: String) -> Bool? {
            let suite = AppIdentity.bundleIdentifier + ".tests.bugA." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { return nil }
            defer { defaults.removePersistentDomain(forName: suite) }
            let learnedWords = LearnedWordsStore(defaults: defaults)
            let h = KeyboardMonitorHarness(
                dictionary: dictionary, inputSources: inputSources, learnedWordsStore: learnedWords
            )
            h.prefs.isAutoSwitchEnabled = false // Double-Shift-only, same isolation as the "/exit" fixture
            inputSources.switchTo(ruLayout)
            guard let strokes = InstantCorrectionFixtures.keystrokes(for: word, reverse: ruReverse) else {
                return nil
            }

            h.type(strokes)
            guard h.monitor.swapLastWordInBuffer() else { return nil } // 1st DS: .recorded

            // The 1st Double Shift above switched the layout to its target
            // (EN, for a ru-typed word) — re-arm ru before the "fresh retype"
            // or these keystrokes render as if typed on the wrong layout.
            inputSources.switchTo(ruLayout)
            h.type(strokes) // fresh retype — same direction, not a toggle
            DebugLog.shared.waitForPendingWrites()
            let before = DebugLog.shared.currentContents
            guard h.monitor.swapLastWordInBuffer() else { return nil } // 2nd DS: .promoted
            DebugLog.shared.waitForPendingWrites()
            let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
            return newLines.contains("learned: inapplicable")
        }

        // "сдуфк" — the flagship non-word own-reading (its EN conversion is
        // "clear", per learning_spec.md / CLAUDE.md v0.8.0): NOT inapplicable.
        if let result = promotedInapplicable(word: "сдуфк") {
            TestRunner.assertTrue(!result, "внесловарная own-сторона ('сдуфк', ru) → 'learned: inapplicable' NOT logged")
        } else {
            TestRunner.assertTrue(false, "'сдуфк' setup: both Double Shift gestures must promote the entry")
        }

        // "дом" — a real ru dictionary word own-reading: inapplicable IS logged.
        if let result = promotedInapplicable(word: "дом") {
            TestRunner.assertTrue(result, "словарная own-сторона ('дом', ru) → 'learned: inapplicable' IS logged")
        } else {
            TestRunner.assertTrue(false, "'дом' setup: both Double Shift gestures must promote the entry")
        }
    }
}


enum ProviderSingleReadGuardTests {
    static func run() {
        TestRunner.section(
            "Bug C fix — learnedWordsProvider reads exceptionsService.autoLearned once per call, not once per candidate"
        )

        final class CountingUserDefaults: UserDefaults {
            var dictionaryReads = 0
            override func dictionary(forKey defaultName: String) -> [String: Any]? {
                if defaultName.hasSuffix("autoLearned") { dictionaryReads += 1 }
                return super.dictionary(forKey: defaultName)
            }
        }

        let suite = AppIdentity.bundleIdentifier + ".tests.bugC." + UUID().uuidString
        guard let counting = CountingUserDefaults(suiteName: suite) else {
            TestRunner.assertTrue(false, "isolated counting UserDefaults suite constructs")
            return
        }
        defer { counting.removePersistentDomain(forName: suite) }

        let prefs = PreferencesService(defaults: counting)
        let exceptions = ExceptionsService(defaults: counting)
        let learnedWords = LearnedWordsStore(defaults: counting)
        let personalFreq = PersonalFrequencyStore(defaults: counting)
        let inputSources = InputSourceManager()
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let analyzer = InstantCorrectionAnalyzer(dictionary: dictionary)
        let replacer = FakeTextReplacer(inputSources: inputSources)

        // 3 promoted non-dictionary personal-frequency entries — without the
        // fix, the closure's `.filter` calls `isAutoLearned` (→ `.autoLearned`,
        // one UserDefaults read) once PER candidate word.
        for word in ["alfa", "bravo", "charlie"] {
            for i in 0..<5 { // promotionThreshold == 5, uniform regardless of isDictionaryWord
                _ = personalFreq.bump(
                    word: word, lang: "en", isDictionaryWord: false, at: Date(timeIntervalSinceNow: TimeInterval(i))
                )
            }
        }
        TestRunner.assertEqual(
            personalFreq.promotedNonDictionaryKeys(lang: "en").count, 3,
            "setup: 3 non-dictionary personal-frequency entries are promoted"
        )

        let monitor = KeyboardMonitor(
            languageDetector: detector, textReplacer: replacer,
            statsService: StatisticsService(), prefsService: prefs,
            exceptionsService: exceptions, yoficatorService: YoficatorService(),
            switchUndoManager: SwitchUndoManager(),
            perAppLayoutService: PerAppLayoutService(inputSourceManager: inputSources, prefsService: prefs),
            instantCorrectionAnalyzer: analyzer,
            secureInputDetector: SecureInputDetector(secureCheck: { false }, axProbe: { false }),
            learnedWordsStore: learnedWords, personalFrequencyStore: personalFreq
        )
        _ = monitor // keeps `learnedWordsProvider` wired for the call below

        counting.dictionaryReads = 0 // isolate the ONE call below from construction-time reads
        _ = detector.learnedWordsProvider("en")
        TestRunner.assertEqual(
            counting.dictionaryReads, 1,
            "exceptionsService.autoLearned is read exactly once per learnedWordsProvider call, not once per candidate word"
        )
    }
}


// MARK: - Avalanche circuit breaker (CLAUDE.md "avalanche" incident: a single
// mistyped Russian word cascaded into ~10 layout switches and 4 Double Shift
// firings inside one second, visible on screen as a mangled `завершftm`).

enum CorrectionAvalancheGuardTests {
    static func run() {
        TestRunner.section("CorrectionAvalancheGuard — pure threshold logic")
        var breaker = CorrectionAvalancheGuard(limit: 3)
        TestRunner.assertTrue(breaker.canFire, "starts able to fire")
        breaker.recordFired()
        TestRunner.assertTrue(breaker.canFire, "1 consecutive fire is still under the limit")
        breaker.recordFired()
        TestRunner.assertTrue(breaker.canFire, "2 consecutive fires are still under the limit")
        breaker.recordFired()
        TestRunner.assertTrue(!breaker.canFire, "3 consecutive fires with no physical input trips the guard")
        breaker.registerPhysicalEvent()
        TestRunner.assertTrue(breaker.canFire, "a genuine physical event resets the fuse")
    }
}


enum QueueReplacementActiveTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.queueIfReplacementActive — flagsChanged is never queued for replay")

        let inputSources = InputSourceManager()
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)

        h.monitor.isPaused = true
        defer { h.monitor.isPaused = false }

        // Root fix for the avalanche: a real Shift transition captured
        // during an active replacement must NOT be queued for a later,
        // squashed-timing replay — that replay is exactly what fed
        // HotkeyManager's Shift-tap gesture detector a false double-tap.
        TestRunner.assertTrue(
            !h.monitor.queueIfReplacementActive(KeyEventSnapshot(type: .flagsChanged, keycode: 56)),
            "a Shift transition during an active pause is NOT queued — avalanche fix"
        )

        // Real letters typed during the pause must still be queued and
        // replayed later (pre-existing, unrelated behavior — must survive).
        TestRunner.assertTrue(
            h.monitor.queueIfReplacementActive(KeyEventSnapshot(type: .keyDown, keycode: 0)),
            "a letter keydown during an active pause is still queued for later replay"
        )
    }
}


// MARK: - Plan 004: replay-burst correctness + failed-replacement trigger handling
//
// Two defects verified by reading the code (see plans/004-replay-correctness.md):
// 1. A replayed key burst (queued while a replacement was in flight) is
//    handed back to `handle(_:)` unanalyzed for suppression only — nothing
//    stops one of THOSE replayed keys from itself completing a word boundary
//    and launching a SECOND, fully automatic replacement (smart case /
//    Yoficator / a snippet) in the middle of the burst.
// 2. A failed replacement (`.layoutSwitchFailed` / `.cancelled`) replays its
//    own suppressed trigger keystroke by re-entering `handle(_:)` exactly
//    like a genuinely queued key — re-analyzing it a second time instead of
//    just rendering it, which double-counts a letter trigger into `buffer`
//    or wipes out the boundary path's own `lastCompletedWord` restore.
enum ReplayBurstAndFailureTests {
    static func run() {
        TestRunner.section("Replay burst & failed-replacement trigger handling (plan 004)")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for the replay-burst/failure fixtures")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = InstantCorrectionFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        let environment = KeyboardMonitorTestEnvironment(inputSources: inputSources)
        defer { environment.restore() }

        func harness() -> KeyboardMonitorHarness {
            // Each call must start every block in the same, known layout —
            // `inputSources` is shared across this suite's `do` blocks, and
            // an earlier block's correction leaves it switched (simulated
            // layout persists on the instance, see InputSourceManager).
            inputSources.switchTo(enLayout)
            let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
            h.prefs.isAutoSwitchEnabled = true
            h.prefs.isInstantCorrectionEnabled = true
            h.prefs.isYoficatorEnabled = true
            h.prefs.isSmartCaseEnabled = true
            h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
            h.exceptions.appExceptions = []
            h.exceptions.wordExceptions = []
            h.exceptions.autoLearned = [:]
            return h
        }

        // "ghbdtn" (en keys) → привет — golden case, fires instant correction
        // on the LAST keystroke (see HeldKeysGameModeGateTests above).
        guard let ghbdtn = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            return
        }
        guard let eshche = InstantCorrectionFixtures.keystrokes(for: "еще", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "'еще': ru fixture can type every character")
            return
        }

        // --- Defect 1: mid-burst replacement --------------------------------
        // Hold "ghbdtn"→привет in flight (.deferred; the exact keystroke
        // instant fires on is an implementation detail of the scorer, not
        // hardcoded here — loop until it does, matching
        // AvalancheGuardWiringTests' own precedent above), then type " еще "
        // WHILE paused — all 5 keystrokes are queued (not analyzed, not
        // rendered yet). Releasing the pending replacement replays them.
        // Without the fix, «еще»'s own trailing space still reaches
        // Yoficator (well inside the 0.2s settling window) and starts a
        // SECOND replacement that this harness never resolves.
        do {
            let h = harness()
            h.replacer.mode = .deferred
            var fired = false
            for stroke in ghbdtn {
                h.press(stroke)
                if h.invocationCount >= 1 { fired = true; break }
            }
            TestRunner.assertTrue(fired, "setup: instant correction fires somewhere in \"ghbdtn\"")

            h.press(49) // space
            for stroke in eshche { h.press(stroke) }
            h.press(49) // space

            // Resolve the held replacement WITHOUT draining the burst yet
            // (completePendingReplacement would do both at once) — captures
            // the actual corrected word this harness/scorer produced,
            // instead of assuming it from a hardcoded "привет".
            h.replacer.completePending()
            let correctedWord = h.screen
            TestRunner.assertTrue(
                !correctedWord.isEmpty && correctedWord.allSatisfy { !$0.isWhitespace },
                "setup: the instant correction produced one corrected word, nothing queued rendered yet"
                    + " (got \"\(correctedWord)\")"
            )

            // `pending` is already nil (consumed above), so this call is
            // just the drain half — dispatches the queued " еще " burst.
            h.completePendingReplacement()

            TestRunner.assertEqual(
                h.invocationCount, 1,
                "no second replacement was started by the replayed burst (defect 1)"
            )
            TestRunner.assertEqual(
                h.screen, correctedWord + " еще ",
                "the queued burst renders exactly as typed — Yoficator does not rewrite «еще» mid-burst"
                    + " (accepted trade-off of the fix)"
            )
        }

        // --- Defect 2, boundary path: a failed replacement replays its
        // trigger untouched --------------------------------------------------
        // `.deferred` (not `.immediate`) is used deliberately here: the
        // completion must run AFTER `handleWordBoundary`'s own
        // "lastCompletedWord = nil" tail (which runs as soon as
        // `processCurrentWord` returns `true`, i.e. the instant the
        // replacement STARTS) — exactly like production, where
        // `TextReplacer.replaceCurrentWord` returns immediately and
        // completes asynchronously. An `.immediate(.layoutSwitchFailed)`
        // here would complete INSIDE that same synchronous call and get
        // overwritten by that same tail regardless of the fix.
        do {
            let h = harness()
            h.prefs.isInstantCorrectionEnabled = false // isolate the boundary path
            h.replacer.mode = .deferred
            h.type(ghbdtn)
            h.press(49) // space — boundary correction starts, held in flight
            TestRunner.assertEqual(h.invocationCount, 1, "setup: boundary correction attempted")

            h.completePendingReplacement(with: .layoutSwitchFailed)
            TestRunner.assertEqual(
                h.screen, "ghbdtn ",
                "setup: a failed layout switch leaves the word on screen exactly as typed"
            )

            h.replacer.mode = .immediate(.success)
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift finds the failed word via the restored lastCompletedWord history"
            )
            TestRunner.assertEqual(
                h.screen, "привет ",
                "Double Shift erases exactly the failed word + trailing space and retypes the real"
                    + " correction — a re-analyzed trigger would have wiped lastCompletedWord instead"
                    + " (defect 2, boundary path)"
            )
        }

        // --- Defect 2, instant path: buffer-length-dependent behaviour -----
        // A cancelled instant correction must not double-count its trigger
        // letter into `buffer`, or a subsequent Double Shift (which reads
        // the LIVE buffer here, not history) scores a corrupted run.
        do {
            let h = harness()
            h.replacer.mode = .immediate(.cancelled)
            h.type(ghbdtn) // instant fires on the last letter, then cancels
            TestRunner.assertEqual(h.invocationCount, 1, "setup: instant correction attempted")
            TestRunner.assertEqual(h.screen, "ghbdtn", "setup: the cancelled word is left on screen exactly as typed")

            h.replacer.mode = .immediate(.success)
            TestRunner.assertTrue(
                h.monitor.swapLastWordInBuffer(),
                "Double Shift finds the live buffer after a cancelled instant correction"
            )
            TestRunner.assertEqual(
                h.screen, "привет",
                "Double Shift converts exactly the 6 typed keystrokes — a double-counted trigger"
                    + " would corrupt the run (defect 2, instant path)"
            )
        }

        // --- Defect 2, instant path: the instant gate is reset on .cancelled
        // ---------------------------------------------------------------
        // Checked via the debug log, not via whether the boundary correction
        // actually FIRES: `finishReplacement()` sets the 0.2s post-
        // replacement cooldown unconditionally (every replacement path funnels
        // through it, including a cancelled one), so a boundary correction
        // attempted immediately afterward is legitimately blocked by the
        // cooldown regardless of this fix. `instantCorrectionGate` is
        // checked BEFORE the cooldown (`processCurrentWord`'s very first
        // lines), so the log line it produces isolates the gate specifically
        // — same technique as BackspaceResetsInstantGateTests above.
        do {
            let h = harness()
            h.replacer.mode = .immediate(.cancelled)
            h.type(ghbdtn) // instant fires on the last letter, then cancels
            TestRunner.assertEqual(h.invocationCount, 1, "setup: instant correction attempted")

            DebugLog.shared.waitForPendingWrites()
            let before = DebugLog.shared.currentContents
            h.press(49) // space — boundary path re-evaluates the same word
            DebugLog.shared.waitForPendingWrites()
            let newLines = String(DebugLog.shared.currentContents.dropFirst(before.count))
            TestRunner.assertTrue(
                !newLines.contains("skip boundary correction: already instant-corrected"),
                "a cancelled instant correction resets instantCorrectionGate — the boundary path is not"
                    + " silently blocked by a correction that never actually happened (defect 2)"
            )
        }
    }
}


enum AvalancheGuardWiringTests {
    static func run() {
        TestRunner.section("KeyboardMonitor — avalanche guard is wired into the real correction path")

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts required for the avalanche guard wiring test")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let enReverse = InstantCorrectionFixtures.reverseMap(for: enLayout, inputSources: inputSources)

        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)
        h.prefs.isAutoSwitchEnabled = true
        h.prefs.isInstantCorrectionEnabled = true
        h.prefs.activeLayoutIDs = [enLayout.id, ruLayout.id]
        inputSources.switchTo(enLayout)

        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 0, "guard starts clean"
        )

        guard let strokes = InstantCorrectionFixtures.keystrokes(for: "ghbdtn", reverse: enReverse) else {
            TestRunner.assertTrue(false, "'ghbdtn': EN fixture can type every character")
            return
        }

        var fired = false
        for stroke in strokes {
            h.press(stroke.keycode, flags: stroke.flags)
            if h.replacer.invocationCount >= 1 { fired = true; break }
        }
        TestRunner.assertTrue(fired, "sanity: instant correction actually fired somewhere in the word")
        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 1,
            "firing a correction records exactly one avalanche-guard hit (checked immediately after it fires,"
                + " before any later keystroke can reset it)"
        )

        // A genuine next physical letter is proof of life — normal typing
        // never trips the breaker.
        if let aKey = enReverse["a"] { h.press(aKey) }
        TestRunner.assertEqual(
            h.monitor.avalancheGuard.consecutiveWithoutPhysicalInput, 0,
            "a real physical keystroke after the correction resets the avalanche guard"
        )
    }
}


enum HotPathStructuralGuardTests {
    static func run() {
        TestRunner.section(
            "Hot path structural guard — handleEvent for an ordinary letter never runs AX/replacement work"
        )

        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }) else {
            TestRunner.skip("EN layout required for the hot-path structural guard")
            return
        }
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()

        // A fake gated on a semaphore, exactly like `SecureInputAXTierTests`
        // below — if this were ever reached SYNCHRONOUSLY from the hot path,
        // `h.press` itself would block on it (bounded to 2s, never a true
        // hang, but the elapsed-time assertion fails unmistakably). A plain
        // "call counter checked right after" would be a race, not a proof:
        // `.async` dispatches to a REAL OS thread that can run concurrently
        // and finish before the calling thread even reaches the assertion.
        let axGate = DispatchSemaphore(value: 0)
        let spySecureDetector = SecureInputDetector(
            secureCheck: { false },
            axProbe: {
                _ = axGate.wait(timeout: .now() + 2.0)
                return false
            }
        )

        let h = KeyboardMonitorHarness(
            dictionary: dictionary, inputSources: inputSources, secureInputDetector: spySecureDetector
        )
        h.prefs.isAutoSwitchEnabled = true
        h.prefs.isInstantCorrectionEnabled = true
        inputSources.switchTo(enLayout)

        // A single, ordinary, correctly-typed letter — the overwhelmingly
        // common case: every keystroke of normal typing before a word gets
        // anywhere near a correction decision.
        let start = CFAbsoluteTimeGetCurrent()
        h.press(0) // "a"
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        axGate.signal() // release the background probe so it doesn't leak into later tests

        TestRunner.assertTrue(
            elapsed < 0.05,
            "the secure-input AX probe is never invoked synchronously from the hot path"
                + " (took \(Int(elapsed * 1000))ms; would be ~2000ms if blocked on the gated fake)"
        )
        TestRunner.assertEqual(
            h.replacer.invocationCount, 0,
            "an ordinary letter never starts a text-replacement transaction"
                + " (AX writes / clipboard / sound only ever run from inside a replacement's completion)"
        )
    }
}


enum TapTimeoutCounterTests {
    static func run() {
        TestRunner.section("KeyboardMonitor — tapDisabledByTimeout increments an observable counter")
        let inputSources = InputSourceManager()
        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let h = KeyboardMonitorHarness(dictionary: dictionary, inputSources: inputSources)

        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 0, "counter starts at 0")
        h.monitor.handleTapDisabled(.tapDisabledByTimeout)
        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 1, "one timeout-disable event increments the counter")
        h.monitor.handleTapDisabled(.tapDisabledByTimeout)
        TestRunner.assertEqual(h.monitor.tapTimeoutDisableCount, 2, "counter accumulates across repeated events")
    }
}


enum CallbackDurationThresholdTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.shouldWarnSlowCallback — pure threshold")
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldWarnSlowCallback(0.005, threshold: 0.015),
            "a 5ms callback is well under the 15ms budget"
        )
        TestRunner.assertTrue(
            KeyboardMonitor.shouldWarnSlowCallback(0.020, threshold: 0.015),
            "a 20ms callback exceeds the 15ms budget and should log a warning"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldWarnSlowCallback(0.015, threshold: 0.015),
            "exactly at the threshold does not warn (strictly greater-than)"
        )
    }
}


enum TapAgeInterpretationTests {
    static func run() {
        TestRunner.section("KeyboardMonitor.chooseTimestampInterpretation — pure decision (Plan 006 Step 5)")
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(
                probesA: [0.5, 1, 2, 3, 4], probesB: [50_000, 60_000, 70_000, 80_000, 90_000]
            ),
            .a,
            "all 5 A-probes plausible (0…1000ms) → A, even though B is implausible"
        )
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(
                probesA: [50_000, 60_000, 70_000, 80_000, 90_000], probesB: [0.5, 1, 2, 3, 4]
            ),
            .b,
            "A implausible, all 5 B-probes plausible → B"
        )
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(
                probesA: [50_000, 60_000, 70_000, 80_000, 90_000],
                probesB: [50_000, 60_000, 70_000, 80_000, 90_000]
            ),
            .none,
            "neither interpretation is plausible on all 5 probes → none, check disabled"
        )
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(
                probesA: [0.5, 1, 2, 3, 90_000], probesB: [0.5, 1, 2, 3, 4]
            ),
            .b,
            "one A-probe out of range fails A entirely, even with 4 of 5 plausible — B wins on merit"
        )
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(probesA: [], probesB: []),
            .none,
            "no probes yet is never plausible"
        )
        TestRunner.assertEqual(
            KeyboardMonitor.chooseTimestampInterpretation(probesA: [0, 1, 2, 3, 1000], probesB: [50_000]),
            .a,
            "0 and 1000ms are inclusive boundaries of the plausible window"
        )
    }
}
#endif
