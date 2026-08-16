import Foundation
import AppKit
import ApplicationServices
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

/// Abstraction around "send backspaces + retype text to the focused app" —
/// the only side-effecting boundary between KeyboardMonitor's correction
/// logic and the live system (real CGEvent posting vs. a deterministic
/// in-memory "screen buffer" model used by the integration test harness in
/// TestRunner.swift). `TextReplacer` conforms via the extension below with
/// no behavior change; production code paths are untouched.
protocol TextReplacing: AnyObject {
    func replaceCurrentWord(length: Int, replacement: String, targetLayout: KeyboardLayout,
                            trailing: String?, trailingAlreadyOnScreen: Bool,
                            completion: @escaping (TextReplacer.Result) -> Void)
    func cancelCurrentReplacement()
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
    /// Pacing for apps whose focused field can't be read back via AX
    /// (terminals: Ghostty & co). There the 2.5ms burst loses keystrokes on
    /// the receiving side — screen recording 09.08.2026: five backspaces sent
    /// in ~12ms, four applied, the leftmost character survived ("./exit",
    /// "йqwerty"). A clean pty accepts the same burst intact, so the loss is
    /// in the GUI delivery chain; since AX gives us no way to verify the
    /// result, the only defense is giving the app time to apply each event.
    private let carefulKeystrokeDelay: useconds_t = 15_000  // 15ms
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

            // One AX round-trip per replacement (not per keystroke); bounded
            // by AXTextSelectionService's 0.15s messaging timeout, so an
            // unresponsive app costs a short stall, not the 6s AX default.
            //
            // "Readable" must mean the field's AX value actually CONTAINS what
            // we are about to erase: Ghostty answers AXValue with an empty
            // string (formally a success), which passed the original nil-check
            // and kept the fast burst — the 09.08 field test lost one
            // backspace per gesture there ("../exit", "...../exit").
            var axReadable = false
            var overlayPid: pid_t?
            if let element = AXTextSelectionService.focusedElement() {
                // Length + caret only — never the value itself. Asking for
                // kAXValueAttribute here copied the app's ENTIRE field across
                // the process boundary just to count it (286 908 characters on
                // one Ghostty probe), on the hot path of every correction.
                var probe = AXTextSelectionService.lengthAndCaret(element)
                if probe == nil {
                    // Field exposes its value but not its character count.
                    // Says so out loud: whether this line shows up in the
                    // field log is the whole question of whether the cheap
                    // path applies to a given app.
                    probe = AXTextSelectionService.valueAndCaret(element)
                        .map { (length: $0.text.utf16.count, caret: $0.caret) }
                    if probe != nil {
                        DebugLog.shared.log(
                            "TR", "ax probe: no char-count attribute — read the whole value",
                            level: .verbose
                        )
                    }
                }
                if let (length, caret) = probe {
                    let need = plan.backspaceCount
                    axReadable = length >= need && caret >= need
                    DebugLog.shared.log(
                        "TR",
                        "ax probe: len=\(length) caret=\(caret) need=\(need)"
                            + " → \(axReadable ? "fast" : "careful")",
                        level: .verbose
                    )
                }
                // Overlay fields (Spotlight, Raycast-style panels) take the
                // keyboard focus WITHOUT becoming the frontmost app — and
                // synthetic CGEvents posted to the session tap land in the
                // frontmost app, not in the focused field. The 09.08 field
                // test typed "ghbdtn" into Spotlight and the correction
                // printed "прив" into the terminal behind it. This is the
                // unrecorded reason the old isSpotlight exclusion existed.
                // Deliver straight to the field's process instead.
                overlayPid = AXTextSelectionService.overlayTargetPid(element)
                if let overlayPid {
                    DebugLog.shared.log(
                        "TR", "overlay delivery: posting to focused field pid=\(overlayPid)"
                    )
                    // Second line of defense for the class of bug that lived
                    // here (Spotlight "ccccara"/"cchr"): the caller's own
                    // resync only covers ONE call site (KeyboardMonitor's
                    // Double Shift run check). Any other overlay replacement
                    // still hands us a `length` derived purely from its typed
                    // model — if that has drifted, erasing the wrong count is
                    // worse than not erasing at all (a stray character
                    // self-heals on the next correction; a wrong erase eats
                    // real text). Read-only, best-effort: no measurement →
                    // no opinion, proceed exactly as before this guard.
                    if let (text, caret) = AXTextSelectionService.valueAndCaret(element),
                       let word = CaretWordExtractor.wordBeforeCaret(text: text, caretUTF16Offset: caret) {
                        let model = plan.backspaceCount
                        let ax = word.word.count
                        if ax != model {
                            DebugLog.shared.log(
                                "TR",
                                "overlay replacement skipped: screen/model mismatch model=\(model) ax=\(ax)"
                            )
                            self.complete(.cancelled, cancellation: cancellation, completion: completion)
                            return
                        }
                    }
                }
            }
            // Overlays swallow keystrokes at the fast burst even when their
            // AX value is perfectly readable: three field episodes (15.08
            // "ccccara"/"cchr", 16.08 "ccfhf" — Spotlight, pid-addressed
            // delivery) each lost exactly one backspace per gesture, and
            // every one logged "overlay pacing: fast axReadable=true". The
            // pre-erase model/screen check above can't catch it — the drift
            // happens DURING delivery, not before it. AX readability says
            // nothing about how fast an overlay drains its event queue, so
            // an overlay always gets the careful pace; overlay queries are
            // short, the cost is ~50-100ms per gesture.
            let pacing = (axReadable && overlayPid == nil)
                ? self.keystrokeDelay : self.carefulKeystrokeDelay
            if !axReadable && overlayPid == nil {
                DebugLog.shared.log("TR", "careful pacing: field not AX-readable")
            } else if overlayPid != nil {
                DebugLog.shared.log(
                    "TR", "overlay pacing: careful (forced; axReadable=\(axReadable))"
                )
            }

            guard self.sendBackspaces(count: plan.backspaceCount, pacing: pacing,
                                      toPid: overlayPid, cancellation: cancellation),
                  self.typeStringFast(plan.payload, pacing: pacing,
                                      toPid: overlayPid, cancellation: cancellation) else {
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

    /// Point of no return: cancellation is honoured only BEFORE the first
    /// backspace goes out. Once even one character has been erased, the
    /// transaction must finish — bailing halfway erased the user's text and
    /// never retyped it, which loses characters permanently. Everything slow
    /// (the layout switch and its verification retries) happens before this,
    /// so the useful cancellation window is untouched.
    /// Session tap for the normal case; straight to the field's process for
    /// overlay panels (see the overlay comment in `replaceCurrentWord`).
    private static func deliver(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func sendBackspaces(
        count: Int,
        pacing: useconds_t,
        toPid pid: pid_t?,
        cancellation: ReplacementCancellationToken
    ) -> Bool {
        guard !cancellation.isCancelled else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
               let ku = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                SyntheticEventMarker.mark(kd)
                SyntheticEventMarker.mark(ku)
                Self.deliver(kd, toPid: pid)
                Self.deliver(ku, toPid: pid)
            }
            usleep(pacing)
        }
        return true
    }

    /// Type string character-by-character via Unicode events.
    /// Per-char (not batched) is required for Electron/web apps — Telegram, Discord,
    /// VSCode, Slack drop multi-char Unicode payloads silently, leaving us with
    /// "text deleted but nothing typed" after backspaces fire.
    /// Never bails out midway for the same reason as `sendBackspaces`: by the
    /// time this runs the original text is already gone from the screen, so an
    /// early return would leave the user with a hole where their word was.
    private func typeStringFast(
        _ text: String,
        pacing: useconds_t,
        toPid pid: pid_t?,
        cancellation: ReplacementCancellationToken
    ) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let utf16 = Array(String(char).utf16)
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                SyntheticEventMarker.mark(kd)
                kd.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                Self.deliver(kd, toPid: pid)
            }
            if let ku = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                SyntheticEventMarker.mark(ku)
                ku.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                Self.deliver(ku, toPid: pid)
            }
            usleep(pacing)
        }
        return true
    }
}

extension TextReplacer: TextReplacing {}
