#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum ShiftStateTests {
    static func run() {
        TestRunner.section("ShiftStateTracker")
        var state = ShiftStateTracker()
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .down,
            "left Shift press is tracked"
        )
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: true), .down,
            "right Shift press is tracked while left remains held"
        )
        TestRunner.assertTrue(state.bothDown, "both Shift keys can be held")
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .up,
            "left release is detected even while aggregate Shift flag stays set"
        )
        TestRunner.assertTrue(state.rightDown && !state.leftDown, "right Shift remains held")
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: false), .up,
            "final right release is detected"
        )

        _ = state.transition(keycode: 56, aggregateShiftPressed: true)
        _ = state.transition(keycode: 60, aggregateShiftPressed: true)
        state.suppressComboReleases()
        TestRunner.assertEqual(
            state.transition(keycode: 56, aggregateShiftPressed: true), .suppressedRelease,
            "combo left release cannot become a ghost press"
        )
        TestRunner.assertEqual(
            state.transition(keycode: 60, aggregateShiftPressed: false), .suppressedRelease,
            "combo right release cannot become a ghost press"
        )
        TestRunner.assertTrue(!state.anyDown, "combo leaves clean Shift state")
    }
}


enum ShiftTapResolverTests {
    static func run() {
        TestRunner.section("ShiftTapResolver")
        var resolver = ShiftTapResolver()
        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: true), .waitForSecondTap,
            "first tap waits when Double Shift is enabled"
        )
        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: true), .performDoubleNow,
            "second tap fires Double Shift even without Single Shift dependency"
        )
        TestRunner.assertTrue(!resolver.hasPendingFirstTap, "double tap consumes pending state")

        TestRunner.assertEqual(
            resolver.registerTap(doubleShiftEnabled: false), .performSingleNow,
            "Single Shift has no 450ms delay when Double Shift is disabled"
        )
        _ = resolver.registerTap(doubleShiftEnabled: true)
        TestRunner.assertTrue(resolver.expireFirstTap(), "pending first tap expires once")
        TestRunner.assertTrue(!resolver.expireFirstTap(), "expired tap cannot fire twice")
        _ = resolver.registerTap(doubleShiftEnabled: true)
        resolver.cancel()
        TestRunner.assertTrue(!resolver.hasPendingFirstTap, "typing cancels pending Shift tap")
    }
}


/// FIX B (13.08.2026, ghost Cmd+Shift+V shift-tap): a fresh Shift-down used
/// to unconditionally reset `anyModifierWithShift = false`, so
/// Cmd↓→Shift↓→V(swallowed)→Shift↑ read as a clean Shift-tap and armed a
/// phantom Single/Double Shift on the NEXT tap within 450ms. The predicate is
/// pure and shared between the mid-hold check and the fresh-down seed.
enum ShiftTapModifierDisqualifierTests {
    static func run() {
        TestRunner.section("HotkeyManager.modifierDisqualifiesShiftTap — pure predicate")
        TestRunner.assertTrue(
            !HotkeyManager.modifierDisqualifiesShiftTap([]),
            "no modifiers: does not disqualify"
        )
        TestRunner.assertTrue(
            !HotkeyManager.modifierDisqualifiesShiftTap(.maskShift),
            "Shift alone: does not disqualify"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskCommand),
            "Cmd: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskControl),
            "Ctrl: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap(.maskAlternate),
            "Alt: disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap([.maskCommand, .maskShift]),
            "Cmd+Shift together (the Cmd+Shift+V case): disqualifies"
        )
        TestRunner.assertTrue(
            HotkeyManager.modifierDisqualifiesShiftTap([.maskAlternate, .maskShift]),
            "Alt+Shift together: disqualifies"
        )
    }
}


/// Replays the hotkey handler itself, with only action dispatch intercepted.
/// No CGEvents, sounds, real preference changes, or layout switches are needed.
enum ComboWindowGuardTests {
    static func run() {
        TestRunner.section("L+R Shift — only a completed bare gesture toggles auto-switch")
        let suite = "QwertySwitcher.ComboReplay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PreferencesService(defaults: defaults)
        prefs.isSplitShiftEnabled = true
        let sources = InputSourceManager()
        let detector = LanguageDetector(dictionary: WordDictionary(), inputSourceManager: sources, prefsService: prefs)
        let replacer = TextReplacer(inputSourceManager: sources)
        let exceptions = ExceptionsService(defaults: defaults)
        let gameMode = GameModeState(defaults: defaults)

        enum Event {
            case flags(UInt16, CGEventFlags, Double)
            case key
            case disableShortcut
        }
        let downL = Event.flags(56, .maskShift, 100)
        let downR = Event.flags(60, .maskShift, 100.05)
        let upR = Event.flags(60, .maskShift, 100.15)
        let upL = Event.flags(56, [], 100.17)
        let cases: [(String, [Event], Int)] = [
            ("both down alone does not toggle early", [downL, downR], 0),
            ("clean chord toggles once on final release", [downL, downR, upR, upL], 1),
            ("reverse release order", [downL, downR, .flags(56, .maskShift, 100.15), .flags(60, [], 100.17)], 1),
            ("reverse press order", [.flags(60, .maskShift, 100), .flags(56, .maskShift, 100.05), upR, upL], 1),
            ("field: key before second Shift", [downL, .key, downR, upR, upL], 0),
            ("field: key after second Shift", [downL, downR, .key, upR, upL], 0),
            ("key between releases", [downL, downR, upR, .key, upL], 0),
            ("command held before Shift", [.flags(56, [.maskShift, .maskCommand], 100), downR, upR, upL], 0),
            ("Caps Lock during chord", [downL, downR, .flags(57, [.maskShift, .maskAlphaShift], 100.06), upR, upL], 0),
            ("Option during chord", [downL, downR, .flags(58, [.maskShift, .maskAlternate], 100.06), upR, upL], 0),
            ("Control during chord", [downL, downR, .flags(59, [.maskShift, .maskControl], 100.06), upR, upL], 0),
            ("modifier during chord", [downL, downR, .flags(55, [.maskShift, .maskCommand], 100.06), .flags(55, .maskShift, 100.07), upR, upL], 0),
            ("stale first Shift cannot toggle", [downL, .flags(60, .maskShift, 102), .flags(60, .maskShift, 102.1), .flags(56, [], 102.2)], 0),
            ("disabled before release", [downL, downR, .disableShortcut, upR, upL], 0),
            ("typing does not poison next clean chord", [downL, downR, .key, upR, upL, .flags(56, .maskShift, 101), .flags(60, .maskShift, 101.05), .flags(60, .maskShift, 101.15), .flags(56, [], 101.17)], 1),
        ]
        for (name, events, expectedToggles) in cases {
            prefs.isAutoSwitchEnabled = true
            prefs.isSplitShiftEnabled = true
            var actions: [String] = []
            let manager = HotkeyManager(
                inputSourceManager: sources, languageDetector: detector,
                textReplacer: replacer, statsService: StatisticsService(),
                prefsService: prefs, exceptionsService: exceptions, gameMode: gameMode,
                actionScheduler: { branch, _ in
                    actions.append(branch)
                    if branch == "toggleAutoSwitch" { prefs.isAutoSwitchEnabled.toggle() }
                }
            )
            for event in events {
                switch event {
                case .flags(let code, let flags, let now):
                    manager.handleFlagsChanged(keycode: code, flags: flags, now: now)
                case .key: manager.markKeyPressed()
                case .disableShortcut: prefs.isSplitShiftEnabled = false
                }
            }
            TestRunner.assertEqual(actions.filter { $0 == "toggleAutoSwitch" }.count, expectedToggles, name)
            TestRunner.assertEqual(prefs.isAutoSwitchEnabled, expectedToggles % 2 == 0, "\(name): preference")
            TestRunner.assertTrue(!actions.contains("doubleShift"), "\(name): no ghost Double Shift")
        }
    }
}


/// FIX A+B+C+D (13.08.2026 diagnosis, Cmd+Shift+V "paste without
/// formatting"): four independent defects in one feature. FIX A's
/// buffer-staleness half already has live coverage
/// (`KeyboardMonitorIntegrationTests`, "Cmd+Shift+V invalidates the stale
/// word buffer"); the rest needs a real pasteboard + focused app the
/// headless harness cannot provide, so it's pinned structurally instead,
/// same precedent as `ReplacementAtomicityGuardTests`.
enum PasteNoFormatGuardTests {
    static func run() {
        TestRunner.section("Cmd+Option+Shift+V — every pass resets state, formatting stripped only when present")

        let coreDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core")

        // --- FIX A + B(1): KeyboardMonitor.handleEvent's kc9 branch --------
        guard let kmText = try? String(
            contentsOf: coreDir.appendingPathComponent("KeyboardMonitor.swift"), encoding: .utf8
        ) else {
            TestRunner.skip("KeyboardMonitor.swift not readable")
            return
        }
        guard let branchStart = kmText.range(of: "keycode == 9 {"),
              let branchEnd = kmText.range(
                of: "// Cmd+Option+Z", range: branchStart.upperBound..<kmText.endIndex
              ) else {
            TestRunner.assertTrue(false, "Cmd+Shift+V branch not found — test needs updating")
            return
        }
        let branch = String(kmText[branchStart.upperBound..<branchEnd.lowerBound])
        TestRunner.assertTrue(
            branch.contains("hotkeyManager?.markKeyPressed()"),
            "FIX B: a swallowed V still registers as a real keypress (kills the ghost shift-tap)"
        )
        TestRunner.assertTrue(
            branch.contains("invalidateEditingContext(reason: \"paste-no-format\")"),
            "FIX A: every pass through the branch resets buffer/runKeystrokes/lastCompletedWord"
        )
        TestRunner.assertTrue(
            branch.contains("pasteNoFormat: swallowed enabled=") && branch.contains("started="),
            "FIX D: the branch is observable in the debug log (metadata only)"
        )

        // --- FIX (15.08.2026): Option is now required on BOTH the shortcut
        // classifier (handlesShortcut) and the handler (handleEvent) — a
        // stray plain Cmd+Shift+V must not match either, or the tap would
        // suppress it in one place while still trying to act on it (or vice
        // versa). Checked directly against the full file text rather than
        // `branch` above, since `branch` starts right after the FIRST
        // "keycode == 9 {" match (inside `handlesShortcut`) and so never
        // contains the condition text leading up to that marker.
        let pasteCondition =
            "flags.contains(.maskCommand) && flags.contains(.maskShift)"
                + " && flags.contains(.maskAlternate) && keycode == 9"
        let pasteConditionCount = kmText.components(separatedBy: pasteCondition).count - 1
        TestRunner.assertEqual(
            pasteConditionCount, 2,
            "both handlesShortcut and handleEvent require Option — bare Cmd+Shift+V matches neither"
        )

        // --- FIX B(2): fresh Shift-down seeds anyModifierWithShift from
        //     THIS event's own flags instead of an unconditional reset.
        guard let hkText = try? String(
            contentsOf: coreDir.appendingPathComponent("HotkeyManager.swift"), encoding: .utf8
        ) else {
            TestRunner.skip("HotkeyManager.swift not readable")
            return
        }
        TestRunner.assertTrue(
            hkText.contains("anyModifierWithShift = Self.modifierDisqualifiesShiftTap(flags)"),
            "FIX B: a fresh Shift-down derives anyModifierWithShift from this event's own flags"
        )

        // --- FIX C + D: handlePasteNoFormat --------------------------------
        guard let funcStart = hkText.range(of: "func handlePasteNoFormat(completion:"),
              let funcEnd = hkText.range(
                of: "private struct PasteboardSnapshot", range: funcStart.upperBound..<hkText.endIndex
              ) else {
            TestRunner.assertTrue(false, "handlePasteNoFormat not found — test needs updating")
            return
        }
        let pasteFn = String(hkText[funcStart.upperBound..<funcEnd.lowerBound])
        TestRunner.assertTrue(
            pasteFn.contains(".pasteboardItems"),
            "FIX C: the pasteboard's actual flavors are inspected before deciding whether to substitute"
        )
        TestRunner.assertTrue(
            pasteFn.contains("onlyPlainText"),
            "FIX C: a pasteboard with no non-plain flavors skips the clear/set substitution entirely"
        )
        TestRunner.assertTrue(
            pasteFn.contains("+ 0.4"),
            "FIX C: the restore delay was widened from 0.15s to 0.4s"
        )
        TestRunner.assertTrue(
            pasteFn.contains("paste-no-format: len=") && pasteFn.contains("flavors=")
                && pasteFn.contains("substituted="),
            "FIX D: the substitution decision is logged with metadata only, never the pasted text"
        )
        TestRunner.assertTrue(
            pasteFn.contains("restore="),
            "FIX D: the restore outcome (done/skipped) is logged"
        )
    }
}
#endif
