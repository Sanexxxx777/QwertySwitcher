#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


/// A replacement is a transaction: the moment the first backspace goes out,
/// the user's word is gone from the screen and only our retype can put it
/// back. Bailing out of either loop halfway therefore destroys text with no
/// way to recover it — the worst failure this app can have. Enforced by
/// reading the source, because the alternative (driving the real
/// `TextReplacer`) posts live CGEvents into whatever the owner is typing —
/// exactly the accident that corrupted his input on 05.08.2026.
enum ReplacementAtomicityGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — a started replacement is never abandoned halfway")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        for (function, loopHeader) in [
            ("sendBackspaces", "for _ in 0..<count {"),
            ("sendBackspacesVerified", "while sent < count + maxExtra {"),
            ("typeStringFast", "for char in text {")
        ] {
            guard let loopStart = text.range(of: loopHeader) else {
                TestRunner.assertTrue(false, "\(function): loop header not found — test needs updating")
                continue
            }
            // Bound the search to the rest of THIS function: the next
            // `private func` (or end of file) is a safe terminator here.
            let rest = String(text[loopStart.upperBound...])
            let functionBody = rest.range(of: "private func").map { String(rest[..<$0.lowerBound]) } ?? rest
            TestRunner.assertTrue(
                !functionBody.contains("isCancelled"),
                "\(function) does not re-check cancellation inside its loop"
                    + " (a mid-loop bail erases text and never retypes it)"
            )
        }
    }
}


/// The status colors carry meaning ("Работает" green, "Заблокировано" red), so
/// they are read, not merely glanced at — WCAG AA text level, 4.5:1, in BOTH
/// appearances. Straight `NSColor.systemGreen` measures 2.22:1 on a light
/// window and was shipped that way; this is the check that makes that a test
/// failure instead of a bug report.
/// Spotlight overlay drift class ("ccccara"/"cchr", field log 14.08.2026
/// 20:13:35-37: `run check: model=4 ax=5 → resynced to screen`, then a later
/// gesture on the same field `model=4 ax=6` — the screen kept growing while
/// the model never moved). `convertWholeRun` measures the real on-screen
/// word via AX whenever it can, but for a letters-only run that is a
/// dictionary judgement, not its call — it falls through to
/// `swapLastWordInBuffer`, which used to re-derive the erase count from
/// `keystrokes.count` alone and throw the measurement away, so the SAME
/// AX-verified drift was never healed, only ever compounded.
/// No live AX inside the headless test harness (a CLI test binary has no
/// focused element to read, and forcing one would make the suite depend on
/// whatever the test machine happens to have focused) — pinned structurally
/// instead, same precedent as `ReplacementAtomicityGuardTests`.
enum RunResyncStructuralGuardTests {
    static func run() {
        TestRunner.section("Double Shift erase count — the scored path reuses convertWholeRun's screen measurement")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/KeyboardMonitor.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("KeyboardMonitor.swift not readable from \(source.path)")
            return
        }

        // 1) convertWholeRun stashes the AX measurement right where it falls
        //    through (letters-only run — nothing for THIS function to do).
        guard let fallthroughMarker = text.range(
            of: "run check: letters only — falls through to the scored path"
        ) else {
            TestRunner.assertTrue(false, "letters-only fallthrough log line not found — test needs updating")
            return
        }
        let precedingGuardBlock = String(text[..<fallthroughMarker.lowerBound]).suffix(400)
        TestRunner.assertTrue(
            precedingGuardBlock.contains("pendingRunResync = onScreen.count"),
            "convertWholeRun stashes the AX-measured screen length before falling through"
        )

        // 2) swapLastWordInBuffer picks it up, gated to the LIVE run — never
        //    a `lastCompletedWord` history snapshot, which is a different
        //    word at a different caret position.
        guard let funcStart = text.range(of: "func swapLastWordInBuffer() -> Bool {") else {
            TestRunner.assertTrue(false, "swapLastWordInBuffer not found — test needs updating")
            return
        }
        guard let lengthMarker = text.range(
            of: "var length = leadingSymbols.count + keystrokes.count",
            range: funcStart.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "erase-length computation not found — test needs updating")
            return
        }
        // 3) Everything BEFORE the erase-length computation — where the
        //    replacement CONTENT (`correctedWord`/`runReplacement`) is
        //    decided from `keystrokes` — must never reference the
        //    measurement. Only the erase count is allowed to move; the
        //    screen decides how much to erase, the keycodes decide what to
        //    type (project invariant).
        let contentSelection = String(text[funcStart.upperBound..<lengthMarker.lowerBound])
        TestRunner.assertTrue(
            !contentSelection.contains("pendingRunResync"),
            "the replacement CONTENT is fully decided before the erase-length override runs"
        )

        guard let callSite = text.range(
            of: "textReplacer.replaceCurrentWord(", range: lengthMarker.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "replaceCurrentWord call site not found — test needs updating")
            return
        }
        let overrideBlock = String(text[lengthMarker.upperBound..<callSite.lowerBound])
        // 4) The override is asymmetric (16.08.2026 fix): erasing LESS than
        //    modelled is adopted unconditionally (clamp), erasing MORE is
        //    gated on proof the extra characters are our own artifact
        //    (extend) — a bare `measured != length` comparison is gone.
        TestRunner.assertTrue(
            overrideBlock.contains("KeyboardMonitor.shouldClampToScreen(model: length, measured: measured)"),
            "the safe direction (erase LESS) is adopted unconditionally via shouldClampToScreen"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("KeyboardMonitor.shouldExtendToScreen("),
            "the dangerous direction (erase MORE) is gated through shouldExtendToScreen, not a bare comparison"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("length = measured"),
            "the erase length is overridden with the measured on-screen length, not the model"
        )
        TestRunner.assertTrue(
            overrideBlock.contains("run check: erase resynced "),
            "the override is logged with the specific 'run check: erase resynced N→M' format"
        )
    }
}


/// Pure unit coverage for `KeyboardMonitor.shouldClampToScreen`/
/// `shouldExtendToScreen` — no AX involved, so unlike the structural guards
/// above this exercises the actual decision logic with real inputs.
enum RunResyncPredicateTests {
    static func run() {
        TestRunner.section("Run-resync erase-length predicate — clamp always, extend only with a suffix match")

        TestRunner.assertTrue(
            KeyboardMonitor.shouldClampToScreen(model: 5, measured: 4),
            "measured < model → clamp (safe direction, unconditional)"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldClampToScreen(model: 5, measured: 5),
            "measured == model → nothing to clamp"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldClampToScreen(model: 5, measured: 6),
            "measured > model is the OTHER predicate's business, not clamp's"
        )

        // modelWord="ghbdt" (typed keycodes), screenWord="gghbdt" (one extra
        // character on screen) — measured−model=1, the screen word ends with
        // what we typed → accept.
        TestRunner.assertTrue(
            KeyboardMonitor.shouldExtendToScreen(
                model: 5, measured: 6, modelWord: "ghbdt", screenWord: "gghbdt"
            ),
            "measured−model=1 and the screen word ends with the typed word → extend"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 5, measured: 8, modelWord: "ghbdt", screenWord: "xxxghbdt"
            ),
            "measured−model=3 exceeds the 2-character budget → reject even with a matching suffix"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 4, modelWord: "ghb", screenWord: "ghx"
            ),
            "screen word does NOT end with the typed word → reject"
        )
        // "x/ghb" ends with "ghb". Until 0.11.0 this predicate accepted it
        // (delta=1 ≤ 2, suffix matches) and relied on `convertWholeRun`
        // routing non-letter screen text away from the scored path. Since
        // the 10.09.2026 field case (`net=-1`: Latin "r" before a Cyrillic
        // model "у" was eaten) the extra prefix itself must be same-script
        // LETTERS — a "/" is neither, so the predicate now refuses on its
        // own, independent of the routing guard. See ResyncExtendGuardTests.
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 4, modelWord: "ghb", screenWord: "x/ghb"
            ),
            "\"x/ghb\": a non-letter in the extra prefix is not a keystroke artifact → reject (0.11.0)"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 3, measured: 6, modelWord: "ghb", screenWord: "xxx/ghb"
            ),
            "same suffix match but delta=3 > 2 → the budget rejects it regardless"
        )
        TestRunner.assertTrue(
            !KeyboardMonitor.shouldExtendToScreen(
                model: 0, measured: 1, modelWord: "", screenWord: "g"
            ),
            "empty modelWord (nothing typed to compare against) → reject"
        )
    }
}


/// Second line of defense for the same drift class: `convertWholeRun`'s
/// resync only covers ONE call site (`RunResyncStructuralGuardTests` above).
/// Any OTHER replacement that ends up delivered to an overlay field still
/// hands `TextReplacer` a `length` derived purely from its caller's typed
/// model. The guard is now ASYMMETRIC (16.08.2026 overlay-verified-erase
/// work): the screen holding LESS than the model still aborts — erasing
/// further would eat text that isn't ours — but the screen holding MORE is
/// cosmetic, not destructive, and is left to the verified erase
/// (`sendBackspacesVerified`) to sort out by watching the caret instead of
/// guessing a count. No live overlay window inside the headless harness, so
/// this reads the source, same precedent as `ReplacementAtomicityGuardTests`.
enum OverlayMismatchGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — an overlay delivery aborts only when the screen holds LESS than the model")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        guard let overlayMarker = text.range(
            of: "overlay delivery: posting to focused field pid=\\(overlayPid)"
        ), let pacingMarker = text.range(
            of: "let pacing = (axReadable && overlayPid == nil)"
        ) else {
            TestRunner.assertTrue(false, "overlay delivery block not found — test needs updating")
            return
        }
        let overlayBlock = String(text[overlayMarker.upperBound..<pacingMarker.lowerBound])

        TestRunner.assertTrue(
            overlayBlock.contains("CaretWordExtractor.wordBeforeCaret"),
            "the overlay guard re-measures the real on-screen word via AX before the replacement fires"
        )
        TestRunner.assertTrue(
            overlayBlock.contains("plan.backspaceCount"),
            "the guard compares against what the caller actually intends to erase"
        )

        guard let ltBranch = overlayBlock.range(of: "if ax < model {"),
              let gtBranch = overlayBlock.range(of: "} else if ax > model {", range: ltBranch.upperBound..<overlayBlock.endIndex)
        else {
            TestRunner.assertTrue(false, "ax < model / ax > model branches not found — test needs updating")
            return
        }
        let lessBranchBody = String(overlayBlock[ltBranch.upperBound..<gtBranch.lowerBound])
        let moreBranchBody = String(overlayBlock[gtBranch.upperBound...])

        TestRunner.assertTrue(
            lessBranchBody.contains("overlay replacement skipped: screen/model mismatch"),
            "screen holding LESS than the model is logged with the specific 'overlay replacement skipped' message"
        )
        TestRunner.assertTrue(
            lessBranchBody.contains("self.complete(.cancelled, cancellation: cancellation, completion: completion)"),
            "screen holding LESS than the model aborts the replacement (.cancelled)"
        )
        TestRunner.assertTrue(
            moreBranchBody.contains("overlay screen longer than model:"),
            "screen holding MORE than the model is logged with the specific 'overlay screen longer than model' message"
        )
        TestRunner.assertTrue(
            !moreBranchBody.contains(".cancelled"),
            "screen holding MORE than the model must NOT cancel the replacement — it's cosmetic, not destructive"
        )

        // Pacing diagnostics are no longer suppressed for the overlay path —
        // TextReplacer.swift used to log nothing at all there.
        guard let eraseDecisionMarker = text.range(
            of: "let eraseSucceeded: Bool", range: pacingMarker.upperBound..<text.endIndex
        ) else {
            TestRunner.assertTrue(false, "pacing block not found — test needs updating")
            return
        }
        let pacingBlock = String(text[pacingMarker.upperBound..<eraseDecisionMarker.lowerBound])
        TestRunner.assertTrue(
            pacingBlock.contains("careful pacing: field not AX-readable"),
            "the non-overlay careful-pacing log is untouched"
        )
        TestRunner.assertTrue(
            pacingBlock.contains("overlay pacing: careful (forced"),
            "an overlay ALWAYS gets the careful pace — Spotlight lost one backspace per "
                + "gesture at the fast burst even with a readable AX value "
                + "(field episodes ccccara/cchr/ccfhf, 15-16.08.2026)"
        )
        TestRunner.assertTrue(
            !pacingBlock.contains("axReadable ? \"fast\" : \"careful\""),
            "the old readability-driven fast/careful switch for overlays is gone"
        )
    }
}


/// `sendBackspacesVerified` (16.08.2026, the "one backspace per gesture"
/// class this closes) reads the caret back between backspaces instead of
/// trusting a fixed count — pinned structurally, same precedent as
/// `ReplacementAtomicityGuardTests`: no live overlay window inside the
/// headless harness.
enum VerifiedEraseGuardTests {
    static func run() {
        TestRunner.section("TextReplacer — verified erase for overlay panels")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/TextReplacer.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("TextReplacer.swift not readable from \(source.path)")
            return
        }

        // (a) the overlay branch calls the verified erase, the plain branch
        // keeps calling the original blind burst — never the other way round.
        guard let eraseDecisionStart = text.range(of: "let eraseSucceeded: Bool"),
              let typeStringCall = text.range(
                of: "self.typeStringFast(plan.payload", range: eraseDecisionStart.upperBound..<text.endIndex
              )
        else {
            TestRunner.assertTrue(false, "erase decision block not found — test needs updating")
            return
        }
        let eraseDecisionBlock = String(text[eraseDecisionStart.upperBound..<typeStringCall.lowerBound])
        TestRunner.assertTrue(
            eraseDecisionBlock.contains("self.sendBackspacesVerified("),
            "the overlay branch calls the verified erase"
        )
        TestRunner.assertTrue(
            eraseDecisionBlock.contains("self.sendBackspaces("),
            "the non-overlay branch still calls the original blind burst"
        )

        // (b)-(e) the verified erase's own safety budget.
        guard let verifiedFuncStart = text.range(of: "private func sendBackspacesVerified(") else {
            TestRunner.assertTrue(false, "sendBackspacesVerified not found — test needs updating")
            return
        }
        let verifiedFuncTail = String(text[verifiedFuncStart.lowerBound...])
        let verifiedFuncBody = verifiedFuncTail.range(of: "\n    private func typeStringFast")
            .map { String(verifiedFuncTail[..<$0.lowerBound]) } ?? verifiedFuncTail

        TestRunner.assertTrue(
            verifiedFuncBody.contains("count + maxExtra"),
            "the erase loop is bounded to count + maxExtra events, never unbounded"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("maxExtra = 2"),
            "at most 2 extra backspaces are allowed to catch up on a measured drift"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("noProgress >= 2"),
            "the loop gives up once the caret stops moving for 2 consecutive events"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("deadline"),
            "the verification loop is bounded by a wall-clock budget, not just an event count"
        )
        TestRunner.assertTrue(
            verifiedFuncBody.contains("erase verified:"),
            "the outcome is logged with the specific 'erase verified:' format"
        )

        // (f) the payload retype is never verified via AX — only the erase is.
        guard let typeFuncStart = text.range(of: "private func typeStringFast(") else {
            TestRunner.assertTrue(false, "typeStringFast not found — test needs updating")
            return
        }
        let typeFuncBody = String(text[typeFuncStart.lowerBound...])
        TestRunner.assertTrue(
            !typeFuncBody.contains("selectionRange"),
            "typeStringFast never verifies via AX — the payload is not read back"
        )
    }
}
#endif
