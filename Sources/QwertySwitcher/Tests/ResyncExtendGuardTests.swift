import Foundation

/// Field 10.09.2026, the only `net≠0` in 1.5 days of verbose log (07:37:34):
/// "r" typed in en, layout switched externally (buffer wiped), "у" typed in
/// ru, Double Shift. `convertWholeRun` measured the screen word "rу" (2)
/// against the 1-key model, `shouldExtendToScreen` accepted it because "rу"
/// ends with "у", the erase was widened to 2 while the payload stayed the
/// 1-key conversion — the user's own "r" was eaten.
///
/// The extend rule now also requires the extra on-screen prefix to be letters
/// of the SAME script as the model: a dropped-keystroke artifact repeats our
/// own typing, a different script is text the user already had. Asymmetry
/// rule (CLAUDE.md): leave a stray character behind rather than erase real
/// text.
enum ResyncExtendGuardTests {
    static func run() {
        TestRunner.section("Resync extend guard — extra prefix must be same-script letters (field 10.09.2026)")

        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 1, measured: 2, modelWord: "у", screenWord: "rу"),
            "field case: Latin 'r' before Cyrillic model 'у' is the user's text — no extend"
        )
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 3, modelWord: "ab", screenWord: "xab"),
            "same-script Latin artifact of 1 letter — extend (the 0.6.16 overlay case)"
        )
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(model: 3, measured: 5, modelWord: "abc", screenWord: "zzabc"),
            "same-script artifact of 2 letters — extend (gap ≤ 2)"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 3, measured: 6, modelWord: "abc", screenWord: "zzzabc"),
            "gap of 3 is more than an overlay drops — no extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 4, modelWord: "ab", screenWord: "x1ab"),
            "a digit in the extra prefix is not a keystroke artifact — no extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 3, modelWord: "ab", screenWord: "xcb"),
            "screen word does not end with the model — no extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 2, modelWord: "ab", screenWord: "ab"),
            "measured == model — nothing to extend"
        )
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 3, modelWord: "ру", screenWord: "кру"),
            "same-script Cyrillic artifact — extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(model: 2, measured: 3, modelWord: "ру", screenWord: "kру"),
            "Latin letter before a Cyrillic model — user's text, no extend"
        )
    }
}
