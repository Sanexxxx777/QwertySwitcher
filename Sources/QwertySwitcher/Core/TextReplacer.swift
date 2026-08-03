import Foundation
import CoreGraphics

struct TextReplacementPlan: Equatable {
    let originalLength: Int
    let replacement: String
    let trailing: String?
    /// True when `trailing` already landed on screen before we started (the
    /// normal case: the user's own keystroke was let through). False only
    /// when WE suppressed that trigger keystroke ourselves (RC-1) — it was
    /// never printed, so it must not be backspaced over, only retyped as
    /// part of the payload.
    var trailingAlreadyOnScreen: Bool = true

    var backspaceCount: Int {
        originalLength + (trailingAlreadyOnScreen ? (trailing?.count ?? 0) : 0)
    }
    var payload: String { replacement + (trailing ?? "") }
}

final class ReplacementCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class TextReplacer {
    enum Result: Equatable {
        case success
        case layoutSwitchFailed
        case cancelled
    }

    private let inputSourceManager: InputSourceManager
    private let keystrokeDelay: useconds_t = 2_500  // 2.5ms — slightly faster than before
    private let replacementQueue = DispatchQueue(
        label: AppIdentity.keyPrefix + "text-replacement",
        qos: .userInteractive
    )
    private var activeCancellation: ReplacementCancellationToken?

    init(inputSourceManager: InputSourceManager) {
        self.inputSourceManager = inputSourceManager
    }

    func cancelCurrentReplacement() {
        activeCancellation?.cancel()
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
                            trailingAlreadyOnScreen: Bool = true,
                            completion: @escaping (Result) -> Void) {
        let cancellation = ReplacementCancellationToken()
        activeCancellation?.cancel()
        activeCancellation = cancellation
        replacementQueue.async { [weak self] in
            guard let self = self else { return }
            let plan = TextReplacementPlan(
                originalLength: length,
                replacement: replacement,
                trailing: trailing,
                trailingAlreadyOnScreen: trailingAlreadyOnScreen
            )

            guard !cancellation.isCancelled else {
                self.complete(.cancelled, cancellation: cancellation, completion: completion)
                return
            }

            // Verify the target first: failed switching must never erase user text.
            var layoutReady = false
            DispatchQueue.main.sync {
                if !cancellation.isCancelled {
                    layoutReady = self.inputSourceManager.switchToAndVerify(targetLayout)
                }
            }
            guard !cancellation.isCancelled else {
                self.complete(.cancelled, cancellation: cancellation, completion: completion)
                return
            }
            guard layoutReady else {
                self.complete(
                    .layoutSwitchFailed,
                    cancellation: cancellation,
                    completion: completion
                )
                return
            }

            guard self.sendBackspaces(count: plan.backspaceCount, cancellation: cancellation),
                  self.typeStringFast(plan.payload, cancellation: cancellation) else {
                self.complete(.cancelled, cancellation: cancellation, completion: completion)
                return
            }

            self.complete(.success, cancellation: cancellation, completion: completion)
        }
    }

    // MARK: - Private

    private func complete(
        _ result: Result,
        cancellation: ReplacementCancellationToken,
        completion: @escaping (Result) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            if self?.activeCancellation === cancellation {
                self?.activeCancellation = nil
            }
            completion(result)
        }
    }

    private func sendBackspaces(
        count: Int,
        cancellation: ReplacementCancellationToken
    ) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard !cancellation.isCancelled else { return false }
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                SyntheticEventMarker.mark(kd)
                SyntheticEventMarker.mark(ku)
                kd.post(tap: .cgAnnotatedSessionEventTap)
                ku.post(tap: .cgAnnotatedSessionEventTap)
            }
            usleep(keystrokeDelay)
        }
        return !cancellation.isCancelled
    }

    /// Type string character-by-character via Unicode events.
    /// Per-char (not batched) is required for Electron/web apps — Telegram, Discord,
    /// VSCode, Slack drop multi-char Unicode payloads silently, leaving us with
    /// "text deleted but nothing typed" after backspaces fire.
    private func typeStringFast(
        _ text: String,
        cancellation: ReplacementCancellationToken
    ) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        for char in text {
            guard !cancellation.isCancelled else { return false }
            let utf16 = Array(String(char).utf16)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                SyntheticEventMarker.mark(kd)
                kd.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                kd.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let ku = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                SyntheticEventMarker.mark(ku)
                ku.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                ku.post(tap: .cgAnnotatedSessionEventTap)
            }
            usleep(keystrokeDelay)
        }
        return !cancellation.isCancelled
    }
}
