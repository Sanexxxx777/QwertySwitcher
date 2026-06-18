import Foundation
import CoreGraphics

final class TextReplacer {
    private let inputSourceManager: InputSourceManager
    private let keystrokeDelay: useconds_t = 2_500  // 2.5ms — slightly faster than before

    init(inputSourceManager: InputSourceManager) {
        self.inputSourceManager = inputSourceManager
    }

    /// - Parameters:
    ///   - length: number of buffered keycodes that form the mistyped word.
    ///   - replacement: corrected word to type.
    ///   - targetLayout: which layout to switch to before typing `replacement`.
    ///   - trailing: the character that triggered the correction (space or
    ///               punctuation like `;` `.` `,`). It was already posted to the
    ///               field by the system *before* our handler fired, so we must
    ///               backspace over it as well and re-type it after the word.
    ///               Pass `nil` for Double Shift / explicit invocations where
    ///               no trigger is in the field.
    func replaceCurrentWord(length: Int, replacement: String, targetLayout: KeyboardLayout,
                            trailing: String? = nil,
                            completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            // Step 1: Delete the mistyped word + the trigger char if any.
            let totalBackspaces = length + (trailing != nil ? 1 : 0)
            self.sendBackspaces(count: totalBackspaces)

            // Step 2: Switch layout
            DispatchQueue.main.sync {
                _ = self.inputSourceManager.switchTo(targetLayout)
            }
            usleep(8_000) // 8ms for layout switch

            // Step 3: Type corrected word (+ trigger) — batch Unicode for speed
            let payload = replacement + (trailing ?? "")
            self.typeStringFast(payload)

            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Private

    private func sendBackspaces(count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                kd.post(tap: .cgAnnotatedSessionEventTap)
                ku.post(tap: .cgAnnotatedSessionEventTap)
            }
            usleep(keystrokeDelay)
        }
    }

    /// Type string character-by-character via Unicode events.
    /// Per-char (not batched) is required for Electron/web apps — Telegram, Discord,
    /// VSCode, Slack drop multi-char Unicode payloads silently, leaving us with
    /// "text deleted but nothing typed" after backspaces fire.
    private func typeStringFast(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let utf16 = Array(String(char).utf16)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                kd.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                kd.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let ku = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                ku.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                ku.post(tap: .cgAnnotatedSessionEventTap)
            }
            usleep(keystrokeDelay)
        }
    }
}
