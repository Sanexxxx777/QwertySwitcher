#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum InputBufferTests {
    static func run() {
        TestRunner.section("InputBuffer")
        TestRunner.assertTrue(InputBuffer.isWordBoundary(49), "space is boundary")
        TestRunner.assertTrue(InputBuffer.isWordBoundary(36), "return is boundary")
        TestRunner.assertTrue(!InputBuffer.isWordBoundary(0), "A is not boundary")
        TestRunner.assertTrue(InputBuffer.isCorrectableBoundary(49), "space triggers correction")
        TestRunner.assertTrue(!InputBuffer.isCorrectableBoundary(36), "return does NOT trigger correction")
        TestRunner.assertTrue(!InputBuffer.isCorrectableBoundary(48), "tab does NOT trigger correction")

        TestRunner.assertTrue(InputBuffer.isLetterKey(0), "A is letter")
        TestRunner.assertTrue(InputBuffer.isLetterKey(43), "comma is letter (б in ru)")
        TestRunner.assertTrue(InputBuffer.isLetterKey(47), "dot is letter (ю in ru)")
        TestRunner.assertTrue(InputBuffer.isDeleteKey(51), "backspace is delete")

        // Punctuation context-aware
        TestRunner.assertTrue(InputBuffer.isPunctuationIn(keycode: 47, languageCode: "en"), "dot is punctuation in en")
        TestRunner.assertTrue(!InputBuffer.isPunctuationIn(keycode: 47, languageCode: "ru"), "dot is letter in ru")
        TestRunner.assertTrue(InputBuffer.isPunctuationIn(keycode: 43, languageCode: "en"), "comma is punctuation in en")
        TestRunner.assertTrue(!InputBuffer.isPunctuationIn(keycode: 0, languageCode: "en"), "A is not punctuation in en")

        // Trigger char mapping — needed so TextReplacer restores what the user typed
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 41, languageCode: "en") == ";", "keycode 41 maps to ;")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 47, languageCode: "en") == ".", "keycode 47 maps to .")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 43, languageCode: "en") == ",", "keycode 43 maps to ,")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 39, languageCode: "en") == "'", "keycode 39 maps to '")
        TestRunner.assertTrue(InputBuffer.punctuationChar(keycode: 0, languageCode: "en") == nil, "A has no punctuation mapping")
        TestRunner.assertTrue(
            InputBuffer.punctuationChar(keycode: 41, languageCode: "en", flags: .maskShift) == ":",
            "shifted punctuation keeps its actual character"
        )
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 18) == "1", "keycode 18 maps to 1")
        TestRunner.assertTrue(
            InputBuffer.digitChar(keycode: 18, flags: .maskShift) == "!",
            "shifted digit keeps its actual character"
        )
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 29) == "0", "keycode 29 maps to 0")
        TestRunner.assertTrue(InputBuffer.digitChar(keycode: 0) == nil, "A has no digit mapping")

        let inputSources = InputSourceManager()
        if let russianLayout = inputSources.availableLayouts.first(where: { $0.languageCode == "ru" }) {
            let shiftedB = inputSources.characterForKeycode(
                43, layout: russianLayout, flags: .maskShift
            )
            let shiftedYu = inputSources.characterForKeycode(
                47, layout: russianLayout, flags: .maskShift
            )
            TestRunner.assertTrue(
                shiftedB?.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } == true,
                "Russian fixture: Shift+б produces a letter"
            )
            TestRunner.assertTrue(
                shiftedYu?.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } == true,
                "Russian fixture: Shift+ю produces a letter"
            )
            TestRunner.assertTrue(
                !InputBuffer.isPunctuationIn(
                    keycode: 43, languageCode: russianLayout.languageCode, flags: .maskShift
                ),
                "Shift+б remains a letter in the active Russian layout"
            )
            TestRunner.assertTrue(
                !InputBuffer.isPunctuationIn(
                    keycode: 47, languageCode: russianLayout.languageCode, flags: .maskShift
                ),
                "Shift+ю remains a letter in the active Russian layout"
            )
            TestRunner.assertEqual(
                inputSources.trailingCharacter(keycode: 44, layout: russianLayout),
                inputSources.characterForKeycode(44, layout: russianLayout),
                "trailing slash key matches the active Russian layout"
            )
            TestRunner.assertEqual(
                inputSources.trailingCharacter(
                    keycode: 19, layout: russianLayout, flags: .maskShift
                ),
                inputSources.characterForKeycode(19, layout: russianLayout, flags: .maskShift),
                "shifted number-row trigger matches the active Russian layout"
            )
        } else {
            TestRunner.skip("Russian layout is required for layout-aware trailing-character checks")
        }

        // Same physical key, different printed symbol per layout — the root
        // cause of the "Да?" instead of "Да," auto-correct trailing-trigger
        // bug. KeyboardMonitor's processCurrentWord/swapLastWordInBuffer
        // recompute a word-closing trigger against the TARGET layout using
        // exactly this call.
        if let ru = inputSources.availableLayouts.first(where: { $0.languageCode == "ru" }),
           let en = inputSources.availableLayouts.first(where: { $0.languageCode == "en" }) {
            TestRunner.assertTrue(
                inputSources.characterForKeycode(44, layout: ru, flags: .maskShift) == ",",
                "Shift+kc44 renders ',' on ЙЦУКЕН"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(44, layout: en, flags: .maskShift) == "?",
                "Shift+kc44 renders '?' on QWERTY"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(26, layout: ru, flags: .maskShift) == "?",
                "Shift+kc26 renders '?' on ЙЦУКЕН"
            )
            TestRunner.assertTrue(
                inputSources.characterForKeycode(26, layout: en, flags: .maskShift) == "&",
                "Shift+kc26 renders '&' on QWERTY"
            )
        } else {
            TestRunner.skip("EN + RU layouts are required for the trigger-symbol layout check")
        }

        let buf = InputBuffer()
        buf.append(1, flags: .maskShift)
        buf.append(2, flags: .maskAlphaShift)
        buf.append(3)
        TestRunner.assertTrue(!buf.isEmpty, "buffer not empty after append")
        let strokes = buf.currentWord()
        TestRunner.assertTrue(strokes[0].flags.contains(.maskShift), "buffer preserves Shift per letter")
        TestRunner.assertTrue(strokes[1].flags.contains(.maskAlphaShift), "buffer preserves CapsLock per letter")
        TestRunner.assertTrue(
            !strokes[0].flags.contains(.maskCommand),
            "buffer stores only casing modifiers"
        )
        buf.clear()
        TestRunner.assertTrue(buf.isEmpty, "buffer empty after clear")

        let overflowBuf = InputBuffer()
        for i in 0..<80 { overflowBuf.append(UInt16(i % 128)) }
        TestRunner.assertTrue(overflowBuf.count <= 64, "ring buffer capped at 64")

        // isGameControlRun (06–08.09.2026 field incident): a game-control
        // spree is plain letters — a run holding a digit, `/`, or a
        // Cyrillic-only ambiguous key is a URL/path/token/password instead.
        let letterRun = Array(repeating: BufferedKeystroke(keycode: 13, flags: []), count: 32)
        TestRunner.assertTrue(
            InputBuffer.isGameControlRun(letterRun), "32 plain letter keystrokes (kc 13) is a game-control run"
        )
        var slashRun = letterRun
        slashRun[10] = BufferedKeystroke(keycode: 44, flags: []) // "/"
        TestRunner.assertTrue(
            !InputBuffer.isGameControlRun(slashRun), "a run containing kc 44 (/) is not a game-control run"
        )
        var dotRun = letterRun
        dotRun[10] = BufferedKeystroke(keycode: 47, flags: []) // "." (ambiguous: ю in ru)
        TestRunner.assertTrue(
            !InputBuffer.isGameControlRun(dotRun), "a run containing kc 47 (.) is not a game-control run"
        )
        var digitRun = letterRun
        digitRun[10] = BufferedKeystroke(keycode: 18, flags: []) // "1"
        TestRunner.assertTrue(
            !InputBuffer.isGameControlRun(digitRun), "a run containing kc 18 (digit) is not a game-control run"
        )
        TestRunner.assertTrue(!InputBuffer.isGameControlRun([]), "an empty run is not a game-control run")
    }
}


enum SecureInputCacheTests {
    static func run() {
        TestRunner.section("SecureInputDetector")
        var now: CFAbsoluteTime = 100
        var secureInputEnabled = false
        var checks = 0
        let detector = SecureInputDetector(
            nowProvider: { now },
            secureCheck: {
                checks += 1
                return secureInputEnabled
            }
        )

        TestRunner.assertTrue(!detector.isSecureInput, "initial non-secure state is reported")
        secureInputEnabled = true
        now += 0.01
        TestRunner.assertTrue(
            detector.isSecureInput,
            "secure input activation is never hidden by a cached false result"
        )
        TestRunner.assertEqual(checks, 2, "non-secure state is rechecked immediately")
    }
}


enum EditingContextPolicyTests {
    static func run() {
        TestRunner.section("EditingContextPolicy")
        TestRunner.assertTrue(
            InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: .maskAlternate),
            "Option-modified input invalidates buffered word and undo history"
        )
        TestRunner.assertTrue(
            InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: .maskCommand),
            "Command shortcuts invalidate buffered word and undo history"
        )
    }
}


enum ReplacementCancellationTests {
    static func run() {
        TestRunner.section("ReplacementCancellation")
        let token = ReplacementCancellationToken()
        TestRunner.assertTrue(!token.isCancelled, "replacement begins active")
        token.cancel()
        TestRunner.assertTrue(token.isCancelled, "context invalidation cancels replacement")

        let next = ReplacementCancellationToken()
        TestRunner.assertTrue(!next.isCancelled, "new replacement gets an independent token")
    }
}


enum SyntheticEventTests {
    static func run() {
        TestRunner.section("SyntheticEventMarker")
        guard ProcessInfo.processInfo.environment["QWERTY_SWITCH_RUN_CGEVENT_TESTS"] == "1" else {
            TestRunner.skip("CGEvent construction requires a live GUI app session on this macOS build")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            TestRunner.assertTrue(false, "CGEvent can be created")
            return
        }
        TestRunner.assertTrue(!SyntheticEventMarker.isMarked(event), "hardware-like event starts unmarked")
        SyntheticEventMarker.mark(event)
        TestRunner.assertTrue(SyntheticEventMarker.isMarked(event), "generated event marker roundtrips")

        guard let replay = CGEvent(
            keyboardEventSource: source, virtualKey: 1, keyDown: true
        ) else {
            TestRunner.assertTrue(false, "replayed CGEvent can be created")
            return
        }
        SyntheticEventMarker.markAsReplayedUserEvent(replay)
        TestRunner.assertTrue(
            SyntheticEventMarker.isReplayedUserEvent(replay),
            "replayed user event marker roundtrips"
        )
        TestRunner.assertTrue(
            !SyntheticEventMarker.isMarked(replay),
            "replayed user event is distinct from generated input"
        )
        TestRunner.assertTrue(
            SyntheticEventMarker.shouldBypass(replay),
            "replayed user event bypasses Qwerty Switcher analysis"
        )
    }
}


enum ReplacementTransactionTests {
    static func run() {
        TestRunner.section("Replacement transaction")
        let plan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: "."
        )
        TestRunner.assertEqual(plan.backspaceCount, 7, "replacement deletes word and exact trailing character")
        TestRunner.assertEqual(plan.payload, "привет.", "replacement restores punctuation exactly")

        // RC-1 fix: when WE suppressed the trigger keystroke ourselves (it
        // never reached the screen), backspace only the word — the trigger
        // is retyped as part of the payload instead of backspaced over.
        let suppressedTriggerPlan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: " ",
            trailingAlreadyOnScreen: false
        )
        TestRunner.assertEqual(
            suppressedTriggerPlan.backspaceCount, 6,
            "a suppressed trigger was never typed — backspace only the word itself"
        )
        TestRunner.assertEqual(
            suppressedTriggerPlan.payload, "привет ",
            "payload still retypes the corrected word AND the suppressed trailing character"
        )

        // Old behavior is preserved by default — Undo and Double Shift pass a
        // trailing character that really IS already on screen and must not
        // be touched by this fix.
        let onScreenTriggerPlan = TextReplacementPlan(
            originalLength: 6,
            replacement: "привет",
            trailing: " "
        )
        TestRunner.assertEqual(
            onScreenTriggerPlan.backspaceCount, 7,
            "default trailingAlreadyOnScreen=true preserves Undo/DoubleShift's old formula"
        )

        let undo = SwitchUndoManager()
        undo.record(
            originalKeycodes: [1, 2, 3],
            originalWord: "руддщ",
            correctedWord: "hello",
            trailing: " ",
            originalLayoutID: "ru",
            targetLayoutID: "en"
        )
        TestRunner.assertTrue(undo.canUndo, "undo remains available until next physical edit")
        TestRunner.assertEqual(undo.consume()?.trailing, " ", "undo transaction preserves trailing space")
        TestRunner.assertTrue(!undo.canUndo, "undo transaction is consumed exactly once")
    }
}


enum PendingUserEventQueueTests {
    static func run() {
        TestRunner.section("PendingUserEventQueue")
        var queue = PendingUserEventQueue<String>()
        TestRunner.assertTrue(queue.isEmpty, "queue starts empty")

        // Real typing during a replacement queues at the back; a trigger we
        // suppressed ourselves (RC-1) must replay FIRST if the replacement
        // fails — enqueueFront places it ahead of anything already queued.
        queue.enqueue("typed-a")
        queue.enqueue("typed-b")
        queue.enqueueFront("suppressed-trigger")
        TestRunner.assertEqual(
            queue.items, ["suppressed-trigger", "typed-a", "typed-b"],
            "suppressed trigger goes first, real typing keeps its order behind it"
        )

        // .success path: discard the suppressed trigger, keep the rest queued.
        var successQueue = queue
        successQueue.discardFront()
        TestRunner.assertEqual(
            successQueue.drain(), ["typed-a", "typed-b"],
            "success discards the suppressed trigger exactly once, replays the rest"
        )
        TestRunner.assertTrue(successQueue.isEmpty, "drain empties the queue")

        // .cancelled / .layoutSwitchFailed path: nothing is discarded, so the
        // suppressed trigger comes back out of drain() for replay.
        var failureQueue = queue
        TestRunner.assertEqual(
            failureQueue.drain(), ["suppressed-trigger", "typed-a", "typed-b"],
            "failure path returns the suppressed trigger for replay, unlike success"
        )
        TestRunner.assertTrue(failureQueue.isEmpty, "drain empties the queue on the failure path too")

        var empty = PendingUserEventQueue<String>()
        empty.discardFront()
        TestRunner.assertTrue(empty.isEmpty, "discardFront on an empty queue is a safe no-op")
    }
}


enum EventRouteTests {
    static func run() {
        TestRunner.section("EventRoute — routing truth table")
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: true, isReplayedUser: false), .ours,
            "our own synthetic keystroke (backspace/retype) routes as ours"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: false, isReplayedUser: true), .replayedUser,
            "a replayed real keystroke routes as replayedUser, analyzed like live typing"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: false, isReplayedUser: false), .physical,
            "genuine hardware input routes as physical"
        )
        TestRunner.assertEqual(
            EventRoute.classify(isMarked: true, isReplayedUser: true), .ours,
            "if both markers were ever set (shouldn't happen), our own marker wins"
        )
    }
}


enum BufferVsScreenModelTests {
    /// A minimal reproduction of the invariant fixed by RC-2: ANY word
    /// boundary — whether typed live or replayed after a paused replacement —
    /// must clear the buffer. Only our own synthetic keystrokes (route ==
    /// .ours) bypass analysis entirely and never reach this logic at all.
    private struct Keystroke {
        let keycode: UInt16
        let route: EventRoute
    }

    private static func simulate(_ script: [Keystroke]) -> InputBuffer {
        let buffer = InputBuffer()
        for stroke in script {
            guard stroke.route != .ours else { continue } // bypassed before analysis
            if InputBuffer.isWordBoundary(stroke.keycode) {
                buffer.clear()
            } else if InputBuffer.isLetterKey(stroke.keycode) {
                buffer.append(stroke.keycode)
            }
        }
        return buffer
    }

    static func run() {
        TestRunner.section("Buffer vs screen — word-boundary model")

        let afterPhysicalSpace = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .physical), // space
        ])
        TestRunner.assertTrue(afterPhysicalSpace.isEmpty, "a physical space clears the buffer")

        // RC-2 case: a real space queued during a paused replacement and
        // replayed afterward is STILL a boundary.
        let afterReplayedSpace = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .replayedUser), // replayed space
        ])
        TestRunner.assertTrue(
            afterReplayedSpace.isEmpty, "a replayed space is STILL a boundary and clears the buffer"
        )

        let secondWord = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 1, route: .physical),
            Keystroke(keycode: 49, route: .replayedUser),
            Keystroke(keycode: 2, route: .physical),
            Keystroke(keycode: 3, route: .physical),
        ])
        TestRunner.assertEqual(
            secondWord.count, 2, "letters after a replayed-space boundary start a fresh word"
        )

        // Our own synthetic keystrokes (backspaces/retype) never reach this
        // analysis — they must not be mistaken for a boundary or for letters.
        let ignoresOwnEvents = simulate([
            Keystroke(keycode: 0, route: .physical),
            Keystroke(keycode: 51, route: .ours), // our own backspace
            Keystroke(keycode: 1, route: .ours),  // our own retyped letter
        ])
        TestRunner.assertEqual(
            ignoresOwnEvents.count, 1, "our own synthetic keystrokes bypass buffer analysis entirely"
        )
    }
}


enum InputSourceSelfSwitchTests {
    static func run() {
        TestRunner.section("InputSourceManager — self-initiated layout change (Fix 3)")
        let us = "com.apple.keylayout.US"
        let ru = "com.apple.keylayout.Russian"
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: us, pendingSelfSwitchID: us
            ),
            .changed(selfInitiated: true),
            "a switch matching our own pending request is self-initiated"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: us, newLayoutID: ru, pendingSelfSwitchID: us
            ),
            .changed(selfInitiated: false),
            "a manual switch to a DIFFERENT layout than we requested is not self-initiated"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: us, pendingSelfSwitchID: nil
            ),
            .changed(selfInitiated: false),
            "with no pending request at all, any switch is manual"
        )

        // Live evidence, debug.log 08.08.2026 — macOS delivers the change
        // notification TWICE for one switch (07:36:24.072 "(self)" +
        // 07:36:24.074 plain). The second one used to be reported as an
        // external switch and wiped the typed-word context 2ms after our own
        // correction finished, which is what made Double Shift immediately
        // answer "no buffer/history — skip".
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: ru, newLayoutID: ru, pendingSelfSwitchID: nil
            ),
            .duplicate,
            "a repeat notification for the already-active layout is not a switch"
        )
        TestRunner.assertEqual(
            InputSourceManager.classifyChange(
                previousLayoutID: nil, newLayoutID: us, pendingSelfSwitchID: nil
            ),
            .changed(selfInitiated: false),
            "the very first notification of a session is a real change, not a duplicate"
        )
    }
}
#endif
