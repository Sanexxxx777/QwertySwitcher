#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


/// Structural guards for the Game Mode wave-2 wiring (gamemode-spec-20260831.md,
/// steps 2-5) — same `#filePath`-source-read precedent as `ComboWindowGuardTests`
/// above, for exactly the properties that don't need (or can't get) live
/// behavioral coverage: ordering inside a function body, and "every direct
/// call routes through the one wrapper".
enum GameModeSourceGuardTests {
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
        TestRunner.section("Game mode — structural guards on KeyboardMonitor.swift / HotkeyManager.swift")

        guard let kmText = readSource("Core/KeyboardMonitor.swift") else { return }

        // Step 2: the sanity-length gate runs strictly before detect() in
        // processCurrentWord, right after the shortWordFloor guard.
        if let funcStart = kmText.range(of: "private func processCurrentWord(") {
            let body = String(kmText[funcStart.upperBound...])
            if let capGate = body.range(of: "InstantCorrectionAnalyzer.maxLength"),
               let detectCall = body.range(of: "languageDetector.detect(keystrokes: keystrokes)") {
                TestRunner.assertTrue(
                    capGate.lowerBound < detectCall.lowerBound,
                    "the sanity-length gate runs before languageDetector.detect( in processCurrentWord"
                )
            } else {
                TestRunner.assertTrue(false, "cap gate or detect() call not found in processCurrentWord — test needs updating")
            }
        } else {
            TestRunner.assertTrue(false, "processCurrentWord not found — test needs updating")
        }

        // Step 3: the hot path (handleEvent) never touches NSWorkspace/
        // AXUIElement/Bundle( — game-mode evidence collection is memory-only.
        if let funcStart = kmText.range(of: "func handleEvent(_ proxy: CGEventTapProxy") {
            let rest = String(kmText[funcStart.upperBound...])
            let body = rest.range(of: "\n    private func handleWordBoundary").map { String(rest[..<$0.lowerBound]) } ?? rest
            for forbidden in ["NSWorkspace", "AXUIElement", "Bundle("] {
                TestRunner.assertTrue(
                    !body.contains(forbidden),
                    "handleEvent's body contains no \(forbidden) (game-mode evidence collection is memory-only)"
                )
            }
        } else {
            TestRunner.assertTrue(false, "handleEvent not found — test needs updating")
        }

        // Step 4: `gameActive` (not a separate branch) is folded directly
        // into the canAutoCorrect expression.
        if let range = kmText.range(of: "let canAutoCorrect = prefsService.isAutoSwitchEnabled") {
            let tail = String(kmText[range.lowerBound...].prefix(400))
            TestRunner.assertTrue(
                tail.contains("!gameActive"),
                "canAutoCorrect's own expression includes !gameActive"
            )
        } else {
            TestRunner.assertTrue(false, "canAutoCorrect declaration not found — test needs updating")
        }

        // Step 5: exactly ONE direct call to
        // exceptionsService.areHotkeysBlockedForCurrentApp() per file — the
        // wrapper's own body (`hotkeysBlocked()` in KeyboardMonitor.swift,
        // `profileBlocksHotkeys()` in HotkeyManager.swift since the 08.09.2026
        // Double Shift release-hatch split it out so Double Shift can tell a
        // silent per-app-profile block apart from a Game Mode block) —
        // everywhere else routes through that one wrapper, never the raw
        // exceptionsService call (StatusBarController is untouched by this
        // wave and deliberately not scanned here — it still checks the
        // per-app profile directly, outside any hotkey path).
        func countDirectCalls(_ path: String, _ text: String?) {
            guard let text else { return }
            var count = 0
            var searchStart = text.startIndex
            let needle = "exceptionsService.areHotkeysBlockedForCurrentApp()"
            while let r = text.range(of: needle, range: searchStart..<text.endIndex) {
                count += 1
                searchStart = r.upperBound
            }
            TestRunner.assertEqual(
                count, 1,
                "\(path): exactly 1 direct call to areHotkeysBlockedForCurrentApp()"
                    + " — inside its own wrapper, nowhere else"
            )
        }
        countDirectCalls("Core/KeyboardMonitor.swift", kmText)
        countDirectCalls("Core/HotkeyManager.swift", readSource("Core/HotkeyManager.swift"))
    }
}


/// Structural guards for the 08.09.2026 game-mode release work — the real
/// exit paths (dictionary lookups against the frontmost app's active
/// layouts, the CGEventTap hot path) can't be exercised live from a headless
/// test binary, same precedent as `GameModeSourceGuardTests` right below.
enum GameModeReleaseGuardTests {
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
        TestRunner.section("Game mode release — structural guards on KeyboardMonitor.swift / HotkeyManager.swift")

        if let kmText = readSource("Core/KeyboardMonitor.swift") {
            // 1) The prose-exit block fires on any real word boundary
            //    (proseBoundary — space/Enter/Tab, field 08.09.2026: Enter
            //    closes a word in chat apps too) and checks the OTHER active
            //    layout when own-reading isn't a dictionary word (field
            //    08.09.2026: 13 Russian words typed in the wrong/English
            //    layout while GAME was active never read as words on their
            //    OWN side).
            if let boundaryMarker = kmText.range(
                of: "if proseBoundary, !captured.isEmpty, gameMode.isActiveForFrontmost()"
            ) {
                let block = String(kmText[boundaryMarker.lowerBound...].prefix(1500))
                TestRunner.assertTrue(
                    block.contains("activeLayouts.first(where:"),
                    "the prose-exit block also checks the OTHER active layout, not just own reading"
                )
                TestRunner.assertTrue(
                    block.contains("gameMode.noteProseWord("),
                    "the proseBoundary/activeLayouts block is the one that calls gameMode.noteProseWord("
                )
            } else {
                TestRunner.assertTrue(false, "proseBoundary prose-exit guard not found — test needs updating")
            }

            // 2) longRun evidence is gated by isGameControlRun on the SAME
            //    line as the note(.longRun) call — a run.count==32 check
            //    without it would readmit URLs/paths/tokens/passwords as
            //    game evidence (field 06–08.09.2026: a browser got a
            //    persisted GAME verdict this way).
            if let longRunLine = kmText.components(separatedBy: "\n")
                .first(where: { $0.contains("gameMode.note(.longRun)") }) {
                TestRunner.assertTrue(
                    longRunLine.contains("InputBuffer.isGameControlRun("),
                    "gameMode.note(.longRun) is called on the SAME line as InputBuffer.isGameControlRun("
                )
            } else {
                TestRunner.assertTrue(false, "gameMode.note(.longRun) line not found — test needs updating")
            }
        }

        // 3) Double Shift's game-mode release hatch: a blocked first press
        //    while GAME is active is logged (not silently swallowed like
        //    the old bare `guard !hotkeysBlocked()`, field 08.09.2026: 17
        //    Double Shifts died silently with zero log trace).
        if let hkText = readSource("Core/HotkeyManager.swift") {
            if let funcStart = hkText.range(of: "private func handleDoubleShift() {") {
                let body = String(hkText[funcStart.upperBound...].prefix(1200))
                TestRunner.assertTrue(
                    body.contains("noteDoubleShiftWhileActive()"),
                    "handleDoubleShift consults gameMode.noteDoubleShiftWhileActive()"
                )
                TestRunner.assertTrue(
                    body.contains("doubleShift blocked: game mode"),
                    "a Double Shift blocked by game mode is logged, not silently dropped"
                )
            } else {
                TestRunner.assertTrue(false, "handleDoubleShift not found — test needs updating")
            }
        }
    }
}


enum GameAppProbeTests {
    static func run() {
        TestRunner.section("GameAppProbe")

        TestRunner.assertTrue(
            GameAppProbe.isGameCategory("public.app-category.games"), "the bare games category is a game"
        )
        TestRunner.assertTrue(
            GameAppProbe.isGameCategory("public.app-category.action-games"), "action-games subcategory is a game"
        )
        TestRunner.assertTrue(
            GameAppProbe.isGameCategory("public.app-category.word-games"), "word-games subcategory is a game"
        )
        TestRunner.assertTrue(
            !GameAppProbe.isGameCategory("public.app-category.developer-tools"), "developer-tools is not a game"
        )
        TestRunner.assertTrue(!GameAppProbe.isGameCategory(nil), "a nil category is not a game")

        TestRunner.assertTrue(
            !GameAppProbe.declaredGame(infoDictionary: nil, bundlePath: nil),
            "no Info.plist and no path is not a declared game"
        )
        TestRunner.assertTrue(
            GameAppProbe.declaredGame(
                infoDictionary: ["LSApplicationCategoryType": "public.app-category.games"], bundlePath: nil
            ),
            "the games category alone declares the app"
        )
        TestRunner.assertTrue(
            GameAppProbe.declaredGame(infoDictionary: ["LSSupportsGameMode": true], bundlePath: nil),
            "LSSupportsGameMode alone declares the app"
        )
        TestRunner.assertTrue(
            GameAppProbe.declaredGame(infoDictionary: ["GCSupportsGameMode": true], bundlePath: nil),
            "GCSupportsGameMode alone declares the app"
        )
        TestRunner.assertTrue(
            GameAppProbe.declaredGame(
                infoDictionary: nil,
                bundlePath: "/Users/x/Library/Application Support/Steam/steamapps/common/Foo/Foo.app"
            ),
            "a /steamapps/ path alone declares the app"
        )
        TestRunner.assertTrue(
            !GameAppProbe.declaredGame(
                infoDictionary: ["LSApplicationCategoryType": "public.app-category.developer-tools"],
                bundlePath: "/Applications/Xcode.app"
            ),
            "an ordinary developer-tools app with no game markers is not declared"
        )
    }
}


enum GameModeStateTests {
    static func run() {
        TestRunner.section("GameModeState")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let declaredInfo: [String: Any] = ["LSApplicationCategoryType": "public.app-category.games"]

        func freshState(now: @escaping () -> Date, isEnabled: @escaping () -> Bool = { true }) -> (GameModeState, String) {
            let suite = AppIdentity.bundleIdentifier + ".tests.gameMode." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return (GameModeState(defaults: .standard, now: now, isEnabled: isEnabled), suite)
            }
            return (GameModeState(defaults: defaults, now: now, isEnabled: isEnabled), suite)
        }

        // declared-вход: no evidence needed, active right after activation
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            state.noteActivation(bundleID: "com.example.declared", infoDictionary: declaredInfo, bundlePath: nil)
            TestRunner.assertTrue(
                state.isActive(bundleID: "com.example.declared"),
                "a declared game is active right after activation, no evidence needed"
            )
        }

        // вход по 1 улике longRun
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            state.noteActivation(bundleID: "com.example.longrun", infoDictionary: nil, bundlePath: nil)
            TestRunner.assertTrue(!state.isActive(bundleID: "com.example.longrun"), "an undeclared app starts inactive")
            state.note(.longRun)
            TestRunner.assertTrue(
                state.isActive(bundleID: "com.example.longrun"), "one longRun clue alone is enough to enter GAME"
            )
        }

        // вход по 1 улике heldKeys
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            state.noteActivation(bundleID: "com.example.heldkeys", infoDictionary: nil, bundlePath: nil)
            state.note(.heldKeys)
            TestRunner.assertTrue(
                state.isActive(bundleID: "com.example.heldkeys"), "one heldKeys clue alone is enough to enter GAME"
            )
        }

        // терминал по поведению в GAME не входит (поле 20.09.2026: «рррр» в Ghostty)
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            state.noteActivation(bundleID: "com.mitchellh.ghostty", infoDictionary: nil, bundlePath: nil)
            state.note(.heldKeys)
            state.note(.longRun)
            TestRunner.assertTrue(
                !state.isActive(bundleID: "com.mitchellh.ghostty"), "a terminal never enters GAME on behavioral clues"
            )
        }

        // выход по 2 прозаическим словам за 30с (порог снижен 4→2, 08.09.2026)
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.prose"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state.note(.longRun)
            state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            clock.advance(1)
            TestRunner.assertTrue(state.isActive(bundleID: bundleID), "1 prose word in 30s is not enough to exit yet")
            state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "the 2nd prose word within 30s exits GAME to TYPING")
        }

        // сброс счётчика прозы уликой (порог 2)
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.prosereset"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state.note(.longRun)
            state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            state.note(.heldKeys) // any clue resets the prose counter
            TestRunner.assertTrue(
                state.isActive(bundleID: bundleID),
                "1 prose word before a clue does not carry over — the clue reset the counter"
            )
            state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            TestRunner.assertTrue(
                state.isActive(bundleID: bundleID), "only 1 prose word counted fresh after the reset is not enough yet"
            )
            state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            TestRunner.assertTrue(
                !state.isActive(bundleID: bundleID), "2 prose words counted fresh after the reset do exit"
            )
        }

        // гистерезис: TYPING + 1 clue re-enters GAME
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.hysteresis"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state.note(.longRun)
            for _ in 0..<2 {
                state.noteProseWord(isDictionaryWord: true, len: 4, hasHeldKeys: false)
            }
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "2 prose words exited to TYPING")
            state.note(.longRun)
            TestRunner.assertTrue(
                state.isActive(bundleID: bundleID), "a single clue in TYPING re-enters GAME (hysteresis)"
            )
        }

        // TTL 30 минут — via the injected clock, no sleep
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            state.noteActivation(bundleID: "com.example.ttl", infoDictionary: declaredInfo, bundlePath: nil)
            state.noteActivation(bundleID: "com.example.other", infoDictionary: nil, bundlePath: nil)
            clock.advance(29 * 60)
            TestRunner.assertTrue(
                state.isActive(bundleID: "com.example.ttl"),
                "within the 30-minute TTL after deactivation, the verdict survives"
            )
            clock.advance(2 * 60)
            TestRunner.assertTrue(
                !state.isActive(bundleID: "com.example.ttl"), "past the 30-minute TTL, the verdict expires"
            )
        }

        // denied перекрывает declared и behavioral
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.denied"
            state.deny(bundleID)
            state.noteActivation(bundleID: bundleID, infoDictionary: declaredInfo, bundlePath: nil)
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "denial overrides a declared game")
            state.note(.longRun)
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "denial overrides behavioral evidence too")
        }

        // НЕ персистит поведенческий вердикт (снято 08.09.2026 — field-инцидент
        // Brave: 3 улики за сессию раньше замораживали GAME навсегда)
        do {
            let suite = AppIdentity.bundleIdentifier + ".tests.gameMode." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = GameModeTestClock(t0)
            let bundleID = "com.example.notpersistedanymore"

            let state1 = GameModeState(defaults: defaults, now: { clock.date }, isEnabled: { true })
            state1.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state1.note(.longRun)
            state1.note(.heldKeys)
            state1.note(.longRun) // 3 clues this session — used to be enough to persist
            state1.noteActivation(bundleID: "com.example.other", infoDictionary: nil, bundlePath: nil) // deactivates bundleID

            let state2 = GameModeState(defaults: defaults, now: { clock.date }, isEnabled: { true })
            state2.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            TestRunner.assertTrue(
                !state2.isActive(bundleID: bundleID),
                "≥3 clues in one session no longer persist a verdict — a fresh instance does not recognize it"
            )
            TestRunner.assertTrue(
                defaults.data(forKey: AppIdentity.keyPrefix + "gameModeAuto") == nil,
                "nothing is ever written under the old gameModeAuto key"
            )
        }

        // очистка устаревшего вердикта 0.9.x при первом запуске новой сборки
        do {
            let suite = AppIdentity.bundleIdentifier + ".tests.gameMode." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else {
                TestRunner.assertTrue(false, "isolated UserDefaults suite constructs")
                return
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let staleKey = AppIdentity.keyPrefix + "gameModeAuto"
            defaults.set("{\"com.example.stale\":1.0}".data(using: .utf8), forKey: staleKey)

            let clock = GameModeTestClock(t0)
            let state = GameModeState(defaults: defaults, now: { clock.date }, isEnabled: { true })
            TestRunner.assertTrue(
                defaults.data(forKey: staleKey) == nil,
                "a stale 0.9.x gameModeAuto verdict is wiped on the very first init"
            )
            state.noteActivation(bundleID: "com.example.stale", infoDictionary: nil, bundlePath: nil)
            TestRunner.assertTrue(
                !state.isActive(bundleID: "com.example.stale"),
                "the wiped stale verdict does not resurrect a GAME verdict for the bundleID it named"
            )
        }

        // isGameModeEnabled=false → isActive всегда false
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date }, isEnabled: { false })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.disabled"
            state.noteActivation(bundleID: bundleID, infoDictionary: declaredInfo, bundlePath: nil)
            TestRunner.assertTrue(
                !state.isActive(bundleID: bundleID), "a declared game does not read as active while the toggle is off"
            )
            state.note(.longRun)
            TestRunner.assertTrue(
                !state.isActive(bundleID: bundleID),
                "behavioral evidence does not read as active while the toggle is off either"
            )
            TestRunner.assertTrue(!state.isActiveForFrontmost(), "isActiveForFrontmost also respects the toggle")
        }

        // Double Shift release hatch (08.09.2026): first press while GAME is
        // active is blocked (remembered), a second press within 8s releases
        // GAME to TYPING and lets the gesture through.
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.dsrelease"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state.note(.longRun)
            TestRunner.assertTrue(
                !state.noteDoubleShiftWhileActive(),
                "the first Double Shift while GAME is active is blocked (remembered, not performed)"
            )
            TestRunner.assertTrue(
                state.isActive(bundleID: bundleID), "the app is still in GAME after the blocked first press"
            )
            clock.advance(3)
            TestRunner.assertTrue(
                state.noteDoubleShiftWhileActive(),
                "a second Double Shift within 8s releases GAME and lets the gesture through"
            )
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "GAME is released to TYPING after the second press")
        }

        // A press outside the 8s window is NOT a release — it's remembered as
        // a fresh first press, and a THIRD press within 8s of THAT one is
        // what finally releases GAME.
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.dsreleasewindow"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            state.note(.longRun)
            TestRunner.assertTrue(!state.noteDoubleShiftWhileActive(), "first Double Shift is blocked")
            clock.advance(9)
            TestRunner.assertTrue(
                !state.noteDoubleShiftWhileActive(),
                "a press 9s after the first (past the 8s window) is blocked too, not treated as a release"
            )
            TestRunner.assertTrue(
                state.isActive(bundleID: bundleID), "GAME is still active — the late press did not release it"
            )
            clock.advance(1)
            TestRunner.assertTrue(
                state.noteDoubleShiftWhileActive(),
                "a third press 1s after the second (within the second press's own 8s window) releases GAME"
            )
            TestRunner.assertTrue(!state.isActive(bundleID: bundleID), "GAME released on the third press")
        }

        // No GAME active → the gesture is never blocked by this method.
        do {
            let clock = GameModeTestClock(t0)
            let (state, suite) = freshState(now: { clock.date })
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let bundleID = "com.example.dsnotgame"
            state.noteActivation(bundleID: bundleID, infoDictionary: nil, bundlePath: nil)
            TestRunner.assertTrue(
                state.noteDoubleShiftWhileActive(), "outside GAME, Double Shift is never blocked by this method"
            )
        }
    }
}


// MARK: - Game Mode (gamemode-spec-20260831.md, wave 1: GameModeState + GameAppProbe)

private final class GameModeTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}
#endif
