#if DEBUG
import Foundation
import CoreGraphics
import CryptoKit
import AppKit


enum CaretWordExtractorTests {
    static func run() {
        TestRunner.section("CaretWordExtractor — Double Shift's word-before-caret path")
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "привет", caretUTF16Offset: 6),
            CaretWordExtractor.Result(word: "привет", utf16Range: NSRange(location: 0, length: 6)),
            "whole single word before the caret at the end of the field"
        )
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "hello ghbdtn", caretUTF16Offset: 12),
            CaretWordExtractor.Result(word: "ghbdtn", utf16Range: NSRange(location: 6, length: 6)),
            "only the LAST word before the caret is taken, not the whole field"
        )
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "мама мыла раму", caretUTF16Offset: 9),
            CaretWordExtractor.Result(word: "мыла", utf16Range: NSRange(location: 5, length: 4)),
            "caret in the MIDDLE of the field takes the word ending there, not the last word overall"
        )
        TestRunner.assertNil(
            CaretWordExtractor.wordBeforeCaret(text: "hello ", caretUTF16Offset: 6),
            "caret right after whitespace has no word to convert"
        )
        TestRunner.assertNil(
            CaretWordExtractor.wordBeforeCaret(text: "hello", caretUTF16Offset: 0),
            "caret at the very start has no word before it"
        )
        // Single letters are ordinary words in Russian (и, а, в, к, с, я, о, у)
        // and the owner hit this directly: five Double Shifts on a lone "b"
        // did nothing (log 07:49:54-57). The floor was lowered to 1 for the
        // EXPLICIT gesture only — automatic correction keeps its own, higher
        // bar, where a false positive would rewrite a shell flag (`rm -f`).
        TestRunner.assertEqual(
            CaretWordExtractor.wordBeforeCaret(text: "a", caretUTF16Offset: 1)?.word,
            "a",
            "single-character word IS convertible via the explicit Double Shift path"
        )
    }
}


enum LayoutTextConverterTests {
    static func run() {
        TestRunner.section("LayoutTextConverter — Double Shift selection/clipboard conversion")
        let inputSources = InputSourceManager()
        guard let enLayout = inputSources.supportedLayouts.first(where: { $0.isEnglish }),
              let ruLayout = inputSources.supportedLayouts.first(where: { $0.isRussian }) else {
            TestRunner.skip("EN + RU layouts are required for selection-conversion fixtures")
            return
        }

        // "ghbdtn" typed on the EN layout is what "привет" looks like on
        // screen when the wrong layout was active — exactly what AX-selected
        // or clipboard text looks like to Double Shift (no original keystrokes).
        let converted = LayoutTextConverter.convert(
            "ghbdtn", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(converted, "привет", "en-typed text converts to the intended Russian word")

        let roundTrip = LayoutTextConverter.convert(
            converted, from: ruLayout, to: enLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(roundTrip, "ghbdtn", "conversion round-trips back to the original keys")

        let capitalized = LayoutTextConverter.convert(
            "Ghbdtn", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(capitalized, "Привет", "capitalization survives the conversion")

        let mixed = LayoutTextConverter.convert(
            "ghbdtn123", from: enLayout, to: ruLayout, inputSourceManager: inputSources
        )
        TestRunner.assertEqual(mixed, "привет123", "characters with no reverse mapping (digits) pass through unchanged")

        // Symbols whose meaning differs between layouts must convert too —
        // this is the selection path, so it covers "I highlighted a sentence
        // with symbols and pressed Double Shift". Keycode 44 is "/" on QWERTY
        // and "." on ЙЦУКЕН; before the reverse map covered symbol keys, the
        // letters moved alphabet and the symbol was left behind (".exit").
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                ".учше", from: ruLayout, to: enLayout, inputSourceManager: inputSources
            ),
            "/exit",
            "a layout-dependent symbol converts along with the word"
        )
        // A whole sentence, both directions. Note what the punctuation does:
        // Russian puts "," on Shift+/ (keycode 44), English puts it on its own
        // key (43). Someone touch-typing Russian while the English layout is
        // active presses Shift+44 for their comma and gets "?" on screen — so
        // "?" converting BACK to "," is correct, and a literal "," in the
        // English text genuinely was the "б" key. Key-for-key is not an
        // approximation here; it is the only reading that reproduces what the
        // person's fingers actually asked for.
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                "ghbdtn? rfr ltkf&", from: enLayout, to: ruLayout, inputSourceManager: inputSources
            ),
            "привет, как дела?",
            "a whole sentence converts — letters and punctuation together"
        )
        TestRunner.assertEqual(
            LayoutTextConverter.convert(
                "привет, как дела?", from: ruLayout, to: enLayout, inputSourceManager: inputSources
            ),
            "ghbdtn? rfr ltkf&",
            "and back the other way — the English direction is not an afterthought"
        )

        let strokes = LayoutTextConverter.keystrokes(for: "ghbdtn", typedOn: enLayout, inputSourceManager: inputSources)
        TestRunner.assertEqual(strokes?.count ?? -1, 6, "reconstructed keystrokes match the source text length")
        TestRunner.assertNil(
            LayoutTextConverter.keystrokes(for: "gh1btn", typedOn: enLayout, inputSourceManager: inputSources),
            "text containing an unmapped character (digit) can't be reconstructed into keystrokes"
        )
    }
}


/// Double Shift on a SELECTION has no headless coverage — it needs a live
/// focused AX element, which the harness cannot provide. What CAN be pinned
/// structurally are the two invariants the 13.08.2026 report was made of:
/// the AX write is verified by reading back (apps answer `.success` and change
/// nothing), and a selection we failed to write is never handed to the
/// buffer/history path (which would convert an unrelated older word).
enum DoubleShiftSelectionGuardTests {
    static func run() {
        TestRunner.section("Double Shift on a selection — write is verified, selection never falls to the buffer")

        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core/HotkeyManager.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            TestRunner.skip("HotkeyManager.swift not readable from \(source.path)")
            return
        }

        guard let writeCall = text.range(of: "AXTextSelectionService.replaceSelectedText") else {
            TestRunner.assertTrue(false, "AX selection write not found — test needs updating")
            return
        }
        let afterWrite = String(text[writeCall.upperBound...])
        let functionTail = afterWrite.range(of: "\n    private func").map { String(afterWrite[..<$0.lowerBound]) }
            ?? afterWrite
        TestRunner.assertTrue(
            functionTail.contains("AXTextSelectionService.selectedText"),
            "the AX write is read back before being reported as success"
                + " (.success only means the app accepted the message)"
        )

        guard let chainStart = text.range(of: "switch convertAXSelection()") else {
            TestRunner.assertTrue(false, "Double Shift chain not found — test needs updating")
            return
        }
        let chain = String(text[chainStart.upperBound...])
        let unwritableCase = chain.range(of: "case .selectionUnwritable:")
        let noSelectionCase = chain.range(of: "case .noSelection:")
        guard let unwritableCase, let noSelectionCase else {
            TestRunner.assertTrue(false, "outcome cases not found — test needs updating")
            return
        }
        let unwritableBody = String(chain[unwritableCase.upperBound..<noSelectionCase.lowerBound])
        TestRunner.assertTrue(
            unwritableBody.contains("probeClipboardSelection"),
            "an unwritable selection goes straight to the clipboard probe"
        )
        TestRunner.assertTrue(
            !unwritableBody.contains("swapLastWordInBuffer"),
            "an unwritable selection is NEVER handed to the buffer/history path"
                + " (it holds an unrelated older word after a mouse selection)"
        )
    }
}


enum SecureInputAXTierTests {
    static func run() {
        TestRunner.section("SecureInputDetector — the AX tier never blocks isSecureInput")

        // Gated (not unconditional) so a genuine wiring regression fails
        // fast with a clear assertion instead of hanging the whole suite.
        let axGate = DispatchSemaphore(value: 0)
        let detector = SecureInputDetector(
            secureCheck: { false },
            axProbe: {
                _ = axGate.wait(timeout: .now() + 2.0)
                return true
            }
        )

        let start = CFAbsoluteTimeGetCurrent()
        let result = detector.isSecureInput
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        axGate.signal() // release the background probe so it doesn't leak into later tests

        TestRunner.assertTrue(!result, "first access returns before the (still gated) AX probe ever resolves")
        TestRunner.assertTrue(
            elapsed < 0.05,
            "isSecureInput returns immediately — the AX probe runs off-thread, never inline"
                + " (took \(Int(elapsed * 1000))ms)"
        )
    }
}
#endif
