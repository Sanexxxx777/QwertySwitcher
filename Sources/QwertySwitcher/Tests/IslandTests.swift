import Foundation

/// Stub registered up front (10.09.2026) so TestRunner.swift is edited exactly
/// once by the orchestrator; the body is filled in by wave W1-C (island layout
/// restore — v0.11.0, field data 08-10.09.2026: of 71 ru→en layout drifts in
/// the owner's 1.5-day verbose log, the next word was Russian and had to be
/// fixed by hand or auto-correction in 49 cases).
enum IslandTests {
    static func run() {
        IslandPolicyTests.run()
        LanguageDetectorRingTests.run()
        IslandStructuralGuardTests.run()
    }
}

/// `IslandPolicy.shouldRestore` is a pure function — no `KeyboardMonitor`/
/// `LanguageDetector` wiring needed, just the ring shapes it's meant to
/// decide on. Table mirrors the acceptance spec exactly.
enum IslandPolicyTests {
    private typealias Slot = LanguageDetector.ContextSlot

    static func run() {
        TestRunner.section("IslandPolicy.shouldRestore — pure decision table")

        let result1 = IslandPolicy.shouldRestore(
            context: [Slot(lang: "ru", corrected: false), Slot(lang: "ru", corrected: false)],
            target: "en", isTerminal: false
        )
        TestRunner.assertEqual(result1 ?? "MISSING", "ru", "[ru, ru] clean, target en → restore ru")

        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "ru", corrected: false), Slot(lang: "en", corrected: true)],
                target: "en", isTerminal: false
            ),
            "[ru, en(corrected)] → nil — mixed languages, not a settled run"
        )
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "en", corrected: false), Slot(lang: "ru", corrected: false)],
                target: "en", isTerminal: false
            ),
            "[en, ru] → nil — mixed languages (other direction)"
        )
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "ru", corrected: false)], target: "en", isTerminal: false
            ),
            "1 slot (< 2 required) → nil"
        )
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(context: [], target: "en", isTerminal: false),
            "0 slots → nil"
        )
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "ru", corrected: false), Slot(lang: "ru", corrected: false)],
                target: "ru", isTerminal: false
            ),
            "target == context language → nil (nothing to restore TO)"
        )
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "ru", corrected: false), Slot(lang: "ru", corrected: false)],
                target: "en", isTerminal: true
            ),
            "terminal app → nil regardless of an otherwise-clean context"
        )
        // A corrected slot in the pair immediately before the island means
        // the owner was still mid-correction/mid-toggle right there, not
        // settled in one language — that's a real run forming, not a
        // one-off foreign word. Deliberately does NOT count as clean
        // context, even though both slots share a language.
        TestRunner.assertNil(
            IslandPolicy.shouldRestore(
                context: [Slot(lang: "ru", corrected: true), Slot(lang: "ru", corrected: false)],
                target: "en", isTerminal: false
            ),
            "[ru(corrected), ru] → nil — a corrected slot means not-yet-settled context"
        )
    }
}

/// Exercises the ring (`LanguageDetector.contextSlots`) through REAL
/// `detect()` calls — same fixture pattern as `DetectorExactnessTests`
/// («ghbdtn»→«привет», «привет» on ru, «hello» on en are all already-proven
/// stable outcomes there and in `NativeContextIncumbentAndOneLetterTests`;
/// reused here rather than picking new, unverified words).
enum LanguageDetectorRingTests {
    static func run() {
        TestRunner.section("LanguageDetector — island context ring (contextSlots)")

        let dictionary = WordDictionary()
        dictionary.waitUntilPrefixIndexReady()
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for LanguageDetector ring fixtures")
            return
        }

        let prefs = PreferencesService()
        let detector = LanguageDetector(dictionary: dictionary, inputSourceManager: inputSources, prefsService: prefs)
        let enReverse = IslandTestFixtures.reverseMap(for: enLayout, inputSources: inputSources)
        let ruReverse = IslandTestFixtures.reverseMap(for: ruLayout, inputSources: inputSources)

        guard let privetStrokes = IslandTestFixtures.keystrokes(for: "привет", reverse: ruReverse),
              let helloStrokes = IslandTestFixtures.keystrokes(for: "hello", reverse: enReverse),
              let ghbdtnStrokes = IslandTestFixtures.keystrokes(for: "ghbdtn", reverse: enReverse),
              let rukuStrokes = IslandTestFixtures.keystrokes(for: "руку", reverse: ruReverse) else {
            TestRunner.assertTrue(false, "island ring fixtures: en/ru layouts can type every character needed")
            return
        }

        // --- 1: fresh ring; noSwitch pushes (word's OWN layout, corrected: false). ---
        detector.resetContext()
        TestRunner.assertTrue(detector.contextSlots.isEmpty, "resetContext: ring starts empty")
        switch detector.detect(keystrokes: privetStrokes, typedLayout: ruLayout) {
        case .noSwitch: break
        case .switchTo: TestRunner.assertTrue(false, "«привет» on ru must stay noSwitch (fixture precondition, see DetectorExactnessTests)")
        }
        TestRunner.assertEqual(detector.contextSlots.count, 1, "ring holds 1 slot after 1 word")
        TestRunner.assertEqual(detector.contextSlots.last?.lang ?? "MISSING", "ru", "noSwitch pushes the word's own layout language")
        TestRunner.assertEqual(detector.contextSlots.last?.corrected ?? true, false, "noSwitch pushes corrected=false")

        // --- 2: switchTo pushes (TARGET language, corrected: true) — NOT
        //        the layout it was typed on. ---
        switch detector.detect(keystrokes: ghbdtnStrokes, typedLayout: enLayout) {
        case .switchTo(let layout, _):
            TestRunner.assertEqual(layout.languageCode, "ru", "'ghbdtn' corrects to ru (fixture precondition)")
        case .noSwitch:
            TestRunner.assertTrue(false, "'ghbdtn' must switch to ru (fixture precondition, see DetectorExactnessTests)")
        }
        TestRunner.assertEqual(detector.contextSlots.count, 2, "ring holds 2 slots after 2 words")
        TestRunner.assertEqual(detector.contextSlots.last?.lang ?? "MISSING", "ru", "switchTo pushes the TARGET language, not the typed-on layout (en)")
        TestRunner.assertEqual(detector.contextSlots.last?.corrected ?? false, true, "switchTo pushes corrected=true")

        // --- 3: capped at 3 — a 4th word drops the OLDEST slot, not the newest. ---
        switch detector.detect(keystrokes: helloStrokes, typedLayout: enLayout) {
        case .noSwitch: break
        case .switchTo: TestRunner.assertTrue(false, "'hello' on en must stay noSwitch (fixture precondition)")
        }
        TestRunner.assertEqual(detector.contextSlots.count, 3, "ring holds 3 slots (cap) after 3 words")

        switch detector.detect(keystrokes: helloStrokes, typedLayout: enLayout) {
        case .noSwitch: break
        case .switchTo: TestRunner.assertTrue(false, "'hello' on en must stay noSwitch (fixture precondition, 2nd call)")
        }
        TestRunner.assertEqual(detector.contextSlots.count, 3, "ring stays capped at 3 after a 4th word")
        TestRunner.assertEqual(
            detector.contextSlots.map(\.lang), ["ru", "en", "en"],
            "the 4th word pushed out the OLDEST slot («привет»'s noSwitch entry), freshest stays last"
        )

        // --- 4: resetContext clears the ring, not just previousWordLanguage. ---
        detector.resetContext()
        TestRunner.assertTrue(detector.contextSlots.isEmpty, "resetContext clears a populated ring")

        // --- 5: setContextLanguage touches ONLY previousWordLanguage. The
        //        ring must stay untouched (still empty here); the bias
        //        change itself is proven indirectly through the SAME
        //        native-context incumbent lock `NativeContextIncumbentAndOneLetterTests`
        //        already exercises: «руку» only stays noSwitch when
        //        `previousWordLanguage == "ru"` — pre-fix it lost to en
        //        «here» on points alone with no established context to
        //        hold the line, and nothing else in this test primes it. ---
        detector.setContextLanguage("ru")
        TestRunner.assertTrue(detector.contextSlots.isEmpty, "setContextLanguage does not push or touch a ring slot")
        switch detector.detect(keystrokes: rukuStrokes, typedLayout: ruLayout) {
        case .switchTo:
            TestRunner.assertTrue(
                false,
                "setContextLanguage(\"ru\") did not actually bias previousWordLanguage"
                    + " — «руку» switched away under what should be an established ru context"
            )
        case .noSwitch:
            TestRunner.assertTrue(true, "setContextLanguage(\"ru\") biases previousWordLanguage exactly like a real ru word would")
        }
    }
}

/// `KeyboardMonitor.restoreIsland` and its 4 call sites have no headless
/// coverage — same reason as `ReplacementAtomicityGuardTests`/
/// `GameModeSourceGuardTests`: driving them needs a live CGEventTap +
/// `TextReplacer` completion. Pinned structurally instead, reading the
/// source directly via `#filePath` (same precedent).
enum IslandStructuralGuardTests {
    private static func readSource(_ path: String) -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            TestRunner.skip("\(path) not readable from \(url.path)")
            return nil
        }
        return text
    }

    static func run() {
        TestRunner.section("Island — structural guards on KeyboardMonitor.swift / HotkeyManager.swift")

        guard let kmText = readSource("Core/KeyboardMonitor.swift") else { return }

        // (a)+(boundary): `processCurrentWord`'s .success restores
        // immediately only when the replay queue is already empty.
        if let funcStart = kmText.range(of: "private func processCurrentWord("),
           let nextFunc = kmText.range(of: "\n    @discardableResult\n    private func applyYoficator(") {
            let scoped = String(kmText[funcStart.upperBound..<nextFunc.lowerBound])
            if let emptyCheck = scoped.range(of: "if self.pendingUserEvents.isEmpty {"),
               let call = scoped.range(of: "self.restoreIsland(path: \"boundary\")") {
                TestRunner.assertTrue(
                    emptyCheck.lowerBound < call.lowerBound,
                    "processCurrentWord: restoreIsland(\"boundary\") fires only inside the pendingUserEvents.isEmpty branch"
                )
            } else {
                TestRunner.assertTrue(false, "processCurrentWord: queue-empty guard or restoreIsland(\"boundary\") call not found — test needs updating")
            }
        } else {
            TestRunner.assertTrue(false, "processCurrentWord not found — test needs updating")
        }

        // (a)+(b): `handleWordBoundary`'s deferred restore fires only under
        // `proseBoundary`, and only once the queue is empty — punctuation
        // boundaries and a non-empty queue both leave the flag pending.
        if let funcStart = kmText.range(of: "private func handleWordBoundary("),
           let nextFunc = kmText.range(of: "\n    @discardableResult\n    private func expandSnippet(") {
            let scoped = String(kmText[funcStart.upperBound..<nextFunc.lowerBound])
            guard let pendingIf = scoped.range(of: "if pendingIslandRestore {"),
                  let proseIf = scoped.range(of: "if proseBoundary {"),
                  let emptyCheck = scoped.range(of: "if pendingUserEvents.isEmpty {"),
                  let call = scoped.range(of: "restoreIsland(path: \"deferred\")"),
                  let punctLog = scoped.range(of: "reason=punctBoundary") else {
                TestRunner.assertTrue(false, "handleWordBoundary: deferred-restore branch not found — test needs updating")
                return
            }
            TestRunner.assertTrue(
                pendingIf.lowerBound < proseIf.lowerBound && proseIf.lowerBound < emptyCheck.lowerBound
                    && emptyCheck.lowerBound < call.lowerBound,
                "handleWordBoundary: restoreIsland(\"deferred\") is nested pendingIslandRestore → proseBoundary → pendingUserEvents.isEmpty, in that order"
            )
            TestRunner.assertTrue(
                call.lowerBound < punctLog.lowerBound,
                "handleWordBoundary: the punctBoundary skip log sits in the proseBoundary==false branch, after the deferred-restore branch in source order"
            )
        } else {
            TestRunner.assertTrue(false, "handleWordBoundary not found — test needs updating")
        }

        // (c): Double Shift's "via run" path (no dictionary judgment at
        // all) never restores the island — structurally, it never calls
        // restoreIsland.
        if let funcStart = kmText.range(of: "private func convertWholeRun("),
           let nextFunc = kmText.range(of: "\n    /// Try to swap the last word currently sitting in the input buffer.") {
            let scoped = String(kmText[funcStart.upperBound..<nextFunc.lowerBound])
            TestRunner.assertTrue(
                !scoped.contains("restoreIsland("),
                "convertWholeRun (Double Shift \"via run\") never calls restoreIsland — no dictionary judgment, no island policy"
            )
        } else {
            TestRunner.assertTrue(false, "convertWholeRun not found — test needs updating")
        }

        if let hkText = readSource("Core/HotkeyManager.swift") {
            TestRunner.assertTrue(
                !hkText.contains("restoreIsland("),
                "HotkeyManager (selection/clipboard/caret Double Shift paths) never calls restoreIsland — only KeyboardMonitor's buffer/history path does"
            )
        }

        // (d): every context-wipe site that resets the learning feedback
        // tracker (Mechanism B, 7 sites) also drops the island flag — scoped
        // past the property declarations so the `private var
        // pendingIslandRestore = false` declaration itself isn't counted.
        if let scopeStart = kmText.range(of: "@objc private func appDidActivate") {
            let scoped = String(kmText[scopeStart.lowerBound...])
            let resetCount = scoped.components(separatedBy: "feedbackTracker.reset()").count - 1
            let flagCount = scoped.components(separatedBy: "pendingIslandRestore = false").count - 1
            TestRunner.assertTrue(
                resetCount == 7,
                "sanity: exactly 7 feedbackTracker.reset() sites (Mechanism B) — found \(resetCount), test needs updating if this changed"
            )
            TestRunner.assertTrue(
                flagCount >= resetCount,
                "pendingIslandRestore = false appears at least as often as feedbackTracker.reset() (\(flagCount) >= \(resetCount))"
            )
        } else {
            TestRunner.assertTrue(false, "appDidActivate not found — test needs updating")
        }

        // (e): restoreIsland switches the layout via the plain, fast
        // `switchTo` — never `switchToAndVerify` (3×8ms of sleep in a path
        // that can run from inside a CGEventTap completion callback).
        if let funcStart = kmText.range(of: "private func restoreIsland(path: String) {"),
           let nextFunc = kmText.range(of: "\n    /// Double Shift on a run the dictionary cannot judge") {
            let scoped = String(kmText[funcStart.upperBound..<nextFunc.lowerBound])
            TestRunner.assertTrue(
                scoped.contains("switchTo("),
                "restoreIsland calls switchTo to change the active layout"
            )
            TestRunner.assertTrue(
                !scoped.contains("switchToAndVerify("),
                "restoreIsland never calls switchToAndVerify (hot-path — no sleeping verification loop)"
            )
        } else {
            TestRunner.assertTrue(false, "restoreIsland not found — test needs updating")
        }
    }
}

/// Copied from `DetectorExactnessTests.swift`'s `private enum
/// DetectorExactnessFixtures` (file-private there, unreachable from this
/// file) — same two helpers, unchanged, same established precedent.
private enum IslandTestFixtures {
    static func reverseMap(
        for layout: KeyboardLayout, inputSources: InputSourceManager
    ) -> [Character: UInt16] {
        var map: [Character: UInt16] = [:]
        for kc in UInt16(0)...UInt16(53) where InputBuffer.isLetterKey(kc) {
            guard let ch = inputSources.characterForKeycode(kc, layout: layout, flags: []),
                  ch.count == 1 else { continue }
            map[Character(ch)] = kc
        }
        return map
    }

    static func keystrokes(for text: String, reverse: [Character: UInt16]) -> [BufferedKeystroke]? {
        var result: [BufferedKeystroke] = []
        result.reserveCapacity(text.count)
        for ch in text {
            guard let kc = reverse[ch] else { return nil }
            result.append(BufferedKeystroke(keycode: kc, flags: []))
        }
        return result
    }
}
