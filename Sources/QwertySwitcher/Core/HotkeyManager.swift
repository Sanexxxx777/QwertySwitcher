import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

final class HotkeyManager {
    private let inputSourceManager: InputSourceManager
    private let languageDetector: LanguageDetector
    private let textReplacer: TextReplacer
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    weak var keyboardMonitor: KeyboardMonitor?
    var switchUndoManager: SwitchUndoManager?

    // Shift state
    private var shiftState = ShiftStateTracker()
    private var shiftTapResolver = ShiftTapResolver()
    private var shiftDownTime: CFAbsoluteTime = 0
    private var anyKeyBetweenShifts = false
    private var anyModifierWithShift = false

    // Double-tap detection
    private var pendingSingleShift: DispatchWorkItem?
    private let doubleTapWindow: CFAbsoluteTime = 0.45  // 450ms — give user more room for 2nd tap
    private let maxShiftHoldForTap: CFAbsoluteTime = 0.4 // 400ms — users often hold slightly longer

    private var lastCapsLockEventTime: CFAbsoluteTime = 0
    private let actionWarnThreshold: CFAbsoluteTime = 0.05 // 50ms

    init(inputSourceManager: InputSourceManager, languageDetector: LanguageDetector,
         textReplacer: TextReplacer, statsService: StatisticsService,
         prefsService: PreferencesService) {
        self.inputSourceManager = inputSourceManager
        self.languageDetector = languageDetector
        self.textReplacer = textReplacer
        self.statsService = statsService
        self.prefsService = prefsService
    }

    func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        let shiftPressed = flags.contains(.maskShift)

        let hadShiftHeld = shiftState.anyDown
        let shiftTransition = shiftState.transition(
            keycode: keycode, aggregateShiftPressed: shiftPressed
        )
        if shiftTransition == .suppressedRelease { return }

        // Only track "modifier appeared WHILE a shift is held" — otherwise a
        // stray Option-down 10 seconds earlier would permanently poison the
        // next shift-tap detection until a second shift happens to reset it.
        if hadShiftHeld
            && (flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)) {
            anyModifierWithShift = true
        }

        // CapsLock as layout switcher (keycode 57)
        let isCapsLock = keycode == 57
        if isCapsLock {
            let now = CFAbsoluteTimeGetCurrent()
            if prefsService.isCapsLockSwitchEnabled,
               now - lastCapsLockEventTime > 0.15 {
                lastCapsLockEventTime = now
                handleSingleShift()
            }
            return
        }

        // Track Shift down/up
        if shiftTransition == .down {
            let wasAlreadyHeld = hadShiftHeld
            shiftDownTime = CFAbsoluteTimeGetCurrent()
            // Clean slate for this shift-cycle. Without this, a stray Option/Cmd
            // press that happened before the shift (not concurrent) would have
            // left these flags set and poisoned the tap detection.
            if !wasAlreadyHeld {
                anyKeyBetweenShifts = false
                anyModifierWithShift = false
            }
        }

        // Left+Right Shift combo — toggle auto-switch
        if shiftState.bothDown && prefsService.isSplitShiftEnabled {
            pendingSingleShift?.cancel()
            pendingSingleShift = nil
            shiftTapResolver.cancel()
            // Off the tap callback, like the single/double shift branches: the
            // toggle plays a sound (first NSSound load hits the disk) and posts
            // a notification that drives SwiftUI, and doing that inline cost
            // 55ms inside the callback (log 07:37:18) — repeated overruns make
            // macOS disable the tap and the user loses keystrokes.
            scheduleAction(branch: "toggleAutoSwitch") { [weak self] in
                self?.handleLeftRightShift()
            }
            shiftState.suppressComboReleases()
            anyKeyBetweenShifts = false
            anyModifierWithShift = false
            // Wipe the tap timer so the following shift-release events don't
            // qualify as taps (holdDuration would look ~0 otherwise and fire a
            // ghost singleShift ~450ms later that flips the layout).
            shiftDownTime = 0
            return
        }

        // Shift released
        if shiftTransition == .up {
            let holdDuration = CFAbsoluteTimeGetCurrent() - shiftDownTime
            let wasTap = holdDuration < maxShiftHoldForTap
                && !anyKeyBetweenShifts
                && !anyModifierWithShift

            if wasTap {
                switch shiftTapResolver.registerTap(
                    doubleShiftEnabled: prefsService.isDoubleShiftEnabled
                ) {
                case .performDoubleNow:
                    pendingSingleShift?.cancel()
                    pendingSingleShift = nil
                    scheduleAction(branch: "doubleShift") { [weak self] in self?.handleDoubleShift() }

                case .waitForSecondTap:
                    pendingSingleShift?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        if self.shiftTapResolver.expireFirstTap(),
                           self.prefsService.isSingleShiftEnabled {
                            self.scheduleAction(branch: "singleShift") { [weak self] in self?.handleSingleShift() }
                        }
                        self.pendingSingleShift = nil
                    }
                    pendingSingleShift = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)

                case .performSingleNow:
                    pendingSingleShift?.cancel()
                    pendingSingleShift = nil
                    if prefsService.isSingleShiftEnabled {
                        scheduleAction(branch: "singleShift") { [weak self] in self?.handleSingleShift() }
                    }
                }
            }

            anyKeyBetweenShifts = false
            anyModifierWithShift = false
        }
    }

    func markKeyPressed() {
        anyKeyBetweenShifts = true
        // If a key was pressed, the pending single shift was a real Shift usage, cancel it
        pendingSingleShift?.cancel()
        pendingSingleShift = nil
        shiftTapResolver.cancel()
    }

    /// Defers a hotkey action (Single/Double Shift) so it NEVER runs nested
    /// inside the CGEventTap callback's own call stack — the callback that
    /// recognized "a shift-tap gesture just completed" always returns
    /// immediately (task: "Double Shift... разрешено выполнить асинхронно").
    /// AX/clipboard/TIS work inside `action` still eventually runs on the
    /// same main run loop (Apple's AXUIElement API has no async/cancellable
    /// variant, so full background execution isn't safe here without a
    /// wider thread-safety audit of `InputSourceManager`/`LanguageDetector` —
    /// out of scope for this pass), so this alone doesn't bound worst-case
    /// latency. Logging when it runs slow at least makes a regression
    /// observable instead of silently reproducing the original bug
    /// (task: "защита от повторения").
    private func scheduleAction(branch: String, _ action: @escaping () -> Void) {
        DispatchQueue.main.async { [actionWarnThreshold] in
            let start = CFAbsoluteTimeGetCurrent()
            action()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            guard elapsed > actionWarnThreshold else { return }
            DebugLog.shared.log(
                "HK",
                "WARNING: slow \(branch) action \(Int((elapsed * 1000).rounded()))ms"
                    + " — likely blocked on AX/clipboard IPC to the focused app"
            )
        }
    }

    // MARK: - Single Shift: switch layout

    private func handleSingleShift() {
        // Same guard `handleDoubleShift` already has: a correction elsewhere
        // may be mid-flight (backspacing/retyping) — switching the active
        // layout out from under it would corrupt that transaction.
        guard keyboardMonitor?.isPaused != true else { return }
        let layouts = languageDetector.activeLayouts
        guard layouts.count >= 2, let current = inputSourceManager.currentLayout else { return }

        // Prefer jumping to a layout with a DIFFERENT language.
        // This avoids bouncing between e.g. ABC and U.S. (both "en").
        let target: KeyboardLayout
        if let nextDifferentLang = layouts.first(where: { $0.languageCode != current.languageCode }) {
            target = nextDifferentLang
        } else {
            let currentIndex = layouts.firstIndex(where: { $0.id == current.id }) ?? 0
            target = layouts[(currentIndex + 1) % layouts.count]
        }
        guard inputSourceManager.switchToAndVerify(target) else {
            DebugLog.shared.log("HK", "singleShift aborted: layout switch verification failed")
            return
        }

        DebugLog.shared.log("HK", "singleShift: \(current.languageCode)→\(target.languageCode)")
        statsService.recordShiftSwitch()
        SoundService.shared.playSwitch(targetLanguageCode: target.languageCode, prefsService: prefsService)
        NotificationCenter.default.post(name: .statsUpdated, object: nil)
    }

    // MARK: - Double Shift: convert selection / last word / word before caret

    /// Priority chain (each step gated by `LicenseService.isEntitled` like
    /// every other conversion, except the final Undo fallback — Undo is
    /// deliberately never license-gated, see CLAUDE.md):
    ///  1. Selected text — Accessibility API first (no side effect); if the
    ///     app's AX tree doesn't expose a selection (Electron, some
    ///     terminals — see v0.2.0 hotfix notes), probe the clipboard instead.
    ///  2. Internal buffer + last-word history, unchanged from before.
    ///  3. Word immediately before the caret, via Accessibility (no keyboard
    ///     hack — NEVER Shift+Option+Left, that is exactly what broke this
    ///     feature in the v0.2.0 hotfix).
    ///  4. Undo the last correction (existing fallback, ungated).
    private func handleDoubleShift() {
        DebugLog.shared.log("HK", "doubleShift triggered")
        guard keyboardMonitor?.isPaused != true else { return }

        if convertAXSelection() { return }
        probeClipboardSelection()
    }

    private func convertAXSelection() -> Bool {
        guard LicenseService.shared.isEntitled else { return false }
        guard let element = AXTextSelectionService.focusedElement(),
              let selected = AXTextSelectionService.selectedText(element) else { return false }
        guard let target = convertedReplacement(for: selected) else { return false }
        guard AXTextSelectionService.replaceSelectedText(target.text, in: element) else {
            DebugLog.shared.log("HK", "doubleShift: AX selection write failed")
            return false
        }
        recordDoubleShiftSuccess(via: "AX selection", length: selected.count, targetLayout: target.layout)
        return true
    }

    private func probeClipboardSelection() {
        ClipboardSelectionProbe.probe { [weak self] copied, snapshot in
            guard let self else { return }
            if let copied, !copied.isEmpty, LicenseService.shared.isEntitled,
               let target = self.convertedReplacement(for: copied) {
                self.pasteConverted(target.text, restoring: snapshot)
                self.recordDoubleShiftSuccess(via: "clipboard selection", length: copied.count, targetLayout: target.layout)
                return
            }
            if copied != nil {
                // We copied a real selection but couldn't/shouldn't convert it
                // (license, URL-like text, already correct) — restore what we
                // clobbered before falling through to the next path.
                snapshot.restore(to: NSPasteboard.general)
            }
            self.continueAfterSelectionPaths()
        }
    }

    private func continueAfterSelectionPaths() {
        if keyboardMonitor?.swapLastWordInBuffer() == true { return }
        if convertWordBeforeCaret() { return }
        if keyboardMonitor?.undoLastCorrection() == true { return }
        // Bundle ID logged here (nowhere else in the Double Shift chain) so a
        // recurring "nothing found" pattern for one specific app is
        // diagnosable from the log alone — AX often can't see into web
        // content (Electron/Chromium apps don't build a full accessibility
        // tree unless an assistive technology like VoiceOver is active).
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        DebugLog.shared.log("HK", "doubleShift: no selection/buffer/history/caret word — skip app=\(app)")
    }

    private func convertWordBeforeCaret() -> Bool {
        guard LicenseService.shared.isEntitled else { return false }
        guard let element = AXTextSelectionService.focusedElement(),
              let (text, caret) = AXTextSelectionService.valueAndCaret(element),
              let extracted = CaretWordExtractor.wordBeforeCaret(text: text, caretUTF16Offset: caret) else { return false }
        guard let target = convertedReplacement(for: extracted.word) else { return false }
        guard AXTextSelectionService.replaceRange(extracted.utf16Range, with: target.text, in: element) else {
            DebugLog.shared.log("HK", "doubleShift: AX caret-word write failed")
            return false
        }
        recordDoubleShiftSuccess(via: "AX caret word", length: extracted.word.count, targetLayout: target.layout)
        return true
    }

    /// Picks the target layout + converted text for text we only have as a
    /// rendered string (no original keystrokes: AX selection, clipboard, word
    /// before caret). The source layout is determined from the text's OWN
    /// script (Cyrillic vs Latin, `LanguageDetector.dominantScriptLanguageCode`)
    /// — NEVER from the currently active layout, which may have nothing to do
    /// with what produced this text (see CLAUDE.md "марже" bug: the active
    /// layout can drift between typing and pressing Double Shift). Prefers
    /// the scored `LanguageDetector.detect` path — same calibration as every
    /// other correction — by reconstructing the keystrokes that would have
    /// typed `text` on the detected source layout; falls back to a blind swap
    /// to "the other" active layout when that reconstruction isn't possible
    /// (mixed content) or the detector sees no reason to switch. Returns nil
    /// (logged) when the text has no letters at all — nothing to guess from.
    private func convertedReplacement(for text: String) -> (text: String, layout: KeyboardLayout)? {
        let layouts = languageDetector.activeLayouts
        guard layouts.count >= 2 else { return nil }
        guard let scriptLanguageCode = LanguageDetector.dominantScriptLanguageCode(text) else {
            DebugLog.shared.log("HK", "doubleShift: text has no letters — can't tell source layout, skip")
            return nil
        }
        guard let sourceLayout = layouts.first(where: { $0.languageCode == scriptLanguageCode }) else { return nil }

        if let keystrokes = LayoutTextConverter.keystrokes(
            for: text, typedOn: sourceLayout, inputSourceManager: inputSourceManager
        ), case .switchTo(let layout, let word) = languageDetector.detect(keystrokes: keystrokes, typedLayout: sourceLayout) {
            return (word, layout)
        }

        guard let other = layouts.first(where: { $0.id != sourceLayout.id }) else { return nil }
        let converted = LayoutTextConverter.convert(
            text, from: sourceLayout, to: other, inputSourceManager: inputSourceManager
        )
        guard !converted.isEmpty, converted != text else { return nil }
        return (converted, other)
    }

    private func recordDoubleShiftSuccess(via source: String, length: Int, targetLayout: KeyboardLayout) {
        // Text is already converted at this point — a failed verification
        // here just means the input source stays on the old layout while the
        // (already-correct) text remains fixed; not worth aborting over.
        _ = inputSourceManager.switchToAndVerify(targetLayout)
        statsService.recordOptionSwitch()
        SoundService.shared.playSwitch(targetLanguageCode: targetLayout.languageCode, prefsService: prefsService)
        NotificationCenter.default.post(name: .statsUpdated, object: nil)
        DebugLog.shared.log("HK", "doubleShift via \(source): len=\(length) target=\(targetLayout.languageCode)")
    }

    private func pasteConverted(_ text: String, restoring snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        if let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {
            kd.flags = .maskCommand
            SyntheticEventMarker.mark(kd)
            kd.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            ku.flags = .maskCommand
            SyntheticEventMarker.mark(ku)
            ku.post(tap: .cgAnnotatedSessionEventTap)
        }
        // Same 0.15s "don't clobber a change made while the paste was in
        // flight" delay as handlePasteNoFormat below.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            snapshot.restore(to: pasteboard)
        }
    }

    // MARK: - Left+Right Shift: toggle auto-switch

    private func handleLeftRightShift() {
        prefsService.isAutoSwitchEnabled.toggle()
        let enabled = prefsService.isAutoSwitchEnabled
        SoundService.shared.playToggle(enabled: enabled, prefsService: prefsService)
        NotificationCenter.default.post(name: .autoSwitchToggled, object: nil)

        if enabled {
            StatusIndicatorController.shared.showEnabled()
        } else {
            StatusIndicatorController.shared.showDisabled()
        }

        // No NSLog here: it is a synchronous IPC hop to logd and it duplicated
        // the DebugLog line below (DebugLog writes asynchronously).
        DebugLog.shared.log("HK", "auto-switch → \(enabled ? "ON" : "OFF")")
    }

    // MARK: - Cmd+Shift+V

    @discardableResult
    func handlePasteNoFormat(completion: @escaping () -> Void) -> Bool {
        let pasteboard = NSPasteboard.general
        guard let str = pasteboard.string(forType: .string) else { return false }
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(str, forType: .string)
        let temporaryChangeCount = pasteboard.changeCount

        let src = CGEventSource(stateID: .hidSystemState)
        let kd = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        kd?.flags = .maskCommand
        if let kd { SyntheticEventMarker.mark(kd) }
        kd?.post(tap: .cgAnnotatedSessionEventTap)
        let ku = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        ku?.flags = .maskCommand // symmetric flags — some Electron apps rely on it
        if let ku { SyntheticEventMarker.mark(ku) }
        ku?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Do not overwrite a clipboard change made by the user or target app
            // while the paste was in flight.
            if pasteboard.changeCount == temporaryChangeCount {
                snapshot.restore(to: pasteboard)
            }
            completion()
        }
        return true
    }
}

/// Clipboard-based selection fallback for apps whose AX tree doesn't expose
/// `kAXSelectedTextAttribute` (Electron/some terminals). Sends Cmd+C, polls
/// `NSPasteboard.changeCount` instead of a blind sleep, and never sends
/// Shift+Option+Left or any other caret-moving combo — see the v0.2.0 hotfix
/// notes in CLAUDE.md for why that ban stands.
private enum ClipboardSelectionProbe {
    private static let pollInterval: TimeInterval = 0.02
    private static let timeout: TimeInterval = 0.12

    /// `completion(nil, snapshot)` means nothing changed within the timeout
    /// (no selection, or the app ignored Cmd+C) — the pasteboard was never
    /// touched by us in that case, so there is nothing to restore. Otherwise
    /// `completion(copiedText, snapshot)`; `snapshot` is the state captured
    /// BEFORE sending Cmd+C, for the caller to restore after it's done using
    /// the clipboard (e.g. pasting a converted replacement back).
    static func probe(completion: @escaping (String?, PasteboardSnapshot) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let before = pasteboard.changeCount

        let src = CGEventSource(stateID: .hidSystemState)
        if let kd = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true) { // 'C'
            kd.flags = .maskCommand
            SyntheticEventMarker.mark(kd)
            kd.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let ku = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) {
            ku.flags = .maskCommand
            SyntheticEventMarker.mark(ku)
            ku.post(tap: .cgAnnotatedSessionEventTap)
        }

        poll(
            pasteboard: pasteboard, before: before, snapshot: snapshot,
            deadline: Date().addingTimeInterval(timeout), completion: completion
        )
    }

    private static func poll(
        pasteboard: NSPasteboard, before: Int, snapshot: PasteboardSnapshot,
        deadline: Date, completion: @escaping (String?, PasteboardSnapshot) -> Void
    ) {
        if pasteboard.changeCount != before {
            completion(pasteboard.string(forType: .string), snapshot)
            return
        }
        guard Date() < deadline else {
            completion(nil, snapshot)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll(pasteboard: pasteboard, before: before, snapshot: snapshot, deadline: deadline, completion: completion)
        }
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        let restoredItems: [NSPasteboardItem] = items.map { fields in
            let item = NSPasteboardItem()
            for (type, data) in fields {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.clearContents()
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

extension Notification.Name {
    static let autoSwitchToggled = Notification.Name(AppIdentity.keyPrefix + "autoSwitchToggled")
    static let statsUpdated = Notification.Name(AppIdentity.keyPrefix + "statsUpdated")
}
