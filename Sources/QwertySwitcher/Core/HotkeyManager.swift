import Foundation
import CoreGraphics
import AppKit

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
            handleLeftRightShift()
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
                    handleDoubleShift()

                case .waitForSecondTap:
                    pendingSingleShift?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        if self.shiftTapResolver.expireFirstTap(),
                           self.prefsService.isSingleShiftEnabled {
                            self.handleSingleShift()
                        }
                        self.pendingSingleShift = nil
                    }
                    pendingSingleShift = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)

                case .performSingleNow:
                    pendingSingleShift?.cancel()
                    pendingSingleShift = nil
                    if prefsService.isSingleShiftEnabled {
                        handleSingleShift()
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

    // MARK: - Single Shift: switch layout

    private func handleSingleShift() {
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
        SoundService.shared.playSwitch(prefsService: prefsService)
        NotificationCenter.default.post(name: .statsUpdated, object: nil)
    }

    // MARK: - Double Shift: convert last word

    private func handleDoubleShift() {
        DebugLog.shared.log("HK", "doubleShift triggered")
        // Single path: internal buffer + last-word history (populated
        // at each word boundary in KeyboardMonitor). Previously there was a
        // Shift+Option+Left + Cmd+C clipboard fallback, but in Electron/web
        // apps (Telegram, Discord, VSCode) Shift+Option+Left is not interpreted
        // as "select word back" — it moves the caret without selecting.
        // Result: cursor jumped left and nothing got converted. We no longer
        // do that; if neither buffer nor history have a word, it's a silent no-op.
        if keyboardMonitor?.swapLastWordInBuffer() == true {
            return
        }
        if keyboardMonitor?.undoLastCorrection() == true { return }
        DebugLog.shared.log("HK", "doubleShift: no buffer and no recent word history — skip")
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

        NSLog("[Hotkey] Auto-switch \(enabled ? "ON" : "OFF")")
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
