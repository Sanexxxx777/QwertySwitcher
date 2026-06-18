import Foundation
import CoreGraphics
import AppKit

final class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let buffer = InputBuffer()
    private let languageDetector: LanguageDetector
    private let textReplacer: TextReplacer
    private let statsService: StatisticsService
    private let prefsService: PreferencesService
    private let exceptionsService: ExceptionsService
    private let yoficatorService: YoficatorService
    private let switchUndoManager: SwitchUndoManager
    private let perAppLayoutService: PerAppLayoutService
    private let secureInputDetector = SecureInputDetector()
    var hotkeyManager: HotkeyManager?
    private(set) var isRunning = false
    var isPaused = false

    // Auto-learning
    private var lastCorrectedOriginal: String?
    private var lastCorrectedReplacement: String?
    private var backspaceCountAfterCorrection = 0

    // Self-capture prevention
    private var lastCorrectionTime: CFAbsoluteTime = 0
    private let correctionCooldown: CFAbsoluteTime = 0.3

    // Stale-buffer eviction: drop accumulated keys if user paused typing too long
    private var lastKeyTime: CFAbsoluteTime = 0
    private let staleBufferTimeout: CFAbsoluteTime = 10.0 // 10 sec idle → clear

    // Last completed word (for Double Shift fallback after space).
    // When user types "ghbdtn " and then hits Double Shift, the main buffer is
    // already empty — we pull keycodes from here instead.
    private var lastCompletedWord: (keycodes: [UInt16], trailing: String, timestamp: CFAbsoluteTime)?

    private let spotlightBundleID = "com.apple.Spotlight"

    init(languageDetector: LanguageDetector, textReplacer: TextReplacer,
         statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, yoficatorService: YoficatorService,
         switchUndoManager: SwitchUndoManager, perAppLayoutService: PerAppLayoutService) {
        self.languageDetector = languageDetector
        self.textReplacer = textReplacer
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.yoficatorService = yoficatorService
        self.switchUndoManager = switchUndoManager
        self.perAppLayoutService = perAppLayoutService

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutDidChange),
            name: .layoutChanged, object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidActivate() {
        buffer.clear()
        languageDetector.resetContext()
    }

    @objc private func layoutDidChange() {
        buffer.clear()
        languageDetector.resetContext()
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        )

        guard let tap = eventTap else {
            NSLog("[KeyboardMonitor] Failed to create event tap")
            DebugLog.shared.log("KM", "ERROR: failed to create CGEventTap (check permissions)")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        NSLog("[KeyboardMonitor] Started")
        DebugLog.shared.log("KM", "event tap started")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .flagsChanged {
            hotkeyManager?.handleFlagsChanged(event)
            return
        }

        guard type == .keyDown else { return }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Cmd+Shift+V
        if flags.contains(.maskCommand) && flags.contains(.maskShift) && keycode == 9 {
            if prefsService.isPasteNoFormatEnabled { hotkeyManager?.handlePasteNoFormat() }
            return
        }

        // Cmd+Option+Z → undo last switch
        // (Plain Cmd+Z is left to the host app to avoid conflicting with its own undo stack.)
        if flags.contains(.maskCommand) && flags.contains(.maskAlternate)
            && keycode == 6 && switchUndoManager.canUndo {
            performUndo()
            return
        }

        // Filter out self-capture FIRST. Our own re-typed characters come back
        // through the event tap; if we let markKeyPressed() see them, it flips
        // `anyKeyBetweenShifts` and cancels any pending singleShift — which
        // kills Double Shift right after an auto-correction (user Shift-Shift
        // within 300ms sees pendingSingleShift == nil). Order matters.
        let inCooldown = (CFAbsoluteTimeGetCurrent() - lastCorrectionTime) < correctionCooldown
        if isPaused { return }
        if inCooldown { return }

        hotkeyManager?.markKeyPressed()
        perAppLayoutService.rememberCurrentLayout()

        // Stale buffer eviction — user paused typing too long, old keys don't belong to current word
        let now = CFAbsoluteTimeGetCurrent()
        if !buffer.isEmpty && (now - lastKeyTime) > staleBufferTimeout {
            buffer.clear()
        }
        lastKeyTime = now

        let isSpotlight = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == spotlightBundleID
        if InputBuffer.isModifierActive(flags) { return }

        // Word-boundary + history capture runs even when auto-switch is OFF,
        // so Double Shift can still swap a word the user just finished typing.
        if InputBuffer.isWordBoundary(keycode) {
            let capturedKeycodes = buffer.currentWord()
            let canAutoCorrect = prefsService.isAutoSwitchEnabled
                && !secureInputDetector.isSecureInput
                && !exceptionsService.isCurrentAppExcepted()
                && !isSpotlight
            if canAutoCorrect && !buffer.isEmpty && InputBuffer.isCorrectableBoundary(keycode) {
                processCurrentWord(trigger: " ")
            }
            if !capturedKeycodes.isEmpty && InputBuffer.isCorrectableBoundary(keycode) {
                lastCompletedWord = (capturedKeycodes, " ", CFAbsoluteTimeGetCurrent())
            }
            buffer.clear()
            return
        }

        if !prefsService.isAutoSwitchEnabled {
            DebugLog.shared.log("KM", "skip: auto-switch OFF")
            // Still track letters so Double Shift can pick them from buffer.
            if InputBuffer.isLetterKey(keycode) { buffer.append(keycode) }
            return
        }
        if secureInputDetector.isSecureInput {
            DebugLog.shared.log("KM", "skip: secure input")
            return
        }
        if exceptionsService.isCurrentAppExcepted() {
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            DebugLog.shared.log("KM", "skip: app exception (\(app))")
            return
        }
        if isSpotlight { return }

        // Auto-learning: backspace after correction
        if InputBuffer.isDeleteKey(keycode) {
            buffer.removeLast()
            if lastCorrectedReplacement != nil {
                backspaceCountAfterCorrection += 1
                if let orig = lastCorrectedOriginal, let repl = lastCorrectedReplacement,
                   backspaceCountAfterCorrection >= repl.count {
                    exceptionsService.learnException(original: orig, corrected: repl)
                    lastCorrectedOriginal = nil
                    lastCorrectedReplacement = nil
                    backspaceCountAfterCorrection = 0
                }
            }
            return
        }

        if lastCorrectedReplacement != nil {
            lastCorrectedOriginal = nil
            lastCorrectedReplacement = nil
            backspaceCountAfterCorrection = 0
        }

        // (word-boundary handled above — before the autoSwitch gate)

        // Context-aware punctuation: e.g. `.` `,` `;` `'` produce real letters in
        // Russian layout (ю, б, ж, э) but punctuation in English. Treat them as a
        // word boundary only when current layout is Latin.
        let currentLang = languageDetector.inputSourceManager.currentLayout?.languageCode
        if InputBuffer.isPunctuationIn(keycode: keycode, languageCode: currentLang) {
            let capturedKeycodes = buffer.currentWord()
            if !buffer.isEmpty {
                let punctChar = InputBuffer.enPunctuationChar(keycode: keycode) ?? ""
                processCurrentWord(trigger: punctChar)
            }
            if !capturedKeycodes.isEmpty {
                let punctChar = InputBuffer.enPunctuationChar(keycode: keycode) ?? ""
                lastCompletedWord = (capturedKeycodes, punctChar, CFAbsoluteTimeGetCurrent())
            }
            buffer.clear()
            return
        }

        if InputBuffer.isLetterKey(keycode) {
            buffer.append(keycode)
        } else if InputBuffer.isNumberOrSpecial(keycode) {
            // Numbers don't get re-typed for us — they already printed before we ran.
            // Pass them as trailing so the word + digit come out in correct order.
            if !buffer.isEmpty {
                let digit = InputBuffer.digitChar(keycode: keycode) ?? ""
                processCurrentWord(trigger: digit)
            }
            buffer.clear()
        } else {
            // Unknown key type — don't try to retype it; just flush the buffer.
            if !buffer.isEmpty { processCurrentWord(trigger: nil) }
            buffer.clear()
        }
    }

    /// Try to swap the last word currently sitting in the input buffer.
    /// Returns true if a correction was applied. Called from Double Shift hotkey.
    @discardableResult
    func swapLastWordInBuffer() -> Bool {
        var keycodes = buffer.currentWord()
        var trailing: String? = nil
        var source = "buffer"

        // Fallback: buffer was cleared by a trailing space/punct — use the
        // history slot we captured at the word boundary. No TTL: as long as
        // the word hasn't been replaced by a new one, Double Shift must work.
        // History is invalidated only when a new word starts or after a
        // successful conversion (line below this function).
        if keycodes.count < 2 {
            if let last = lastCompletedWord, last.keycodes.count >= 2 {
                keycodes = last.keycodes
                trailing = last.trailing
                source = "history"
            }
        }

        guard keycodes.count >= 2 else { return false }

        let layouts = languageDetector.inputSourceManager.availableLayouts
        guard layouts.count >= 2, let currentLayout = languageDetector.inputSourceManager.currentLayout else { return false }

        // Decide target: if detector finds a valid other layout, use it.
        // Otherwise fall back to "the other layout" (force swap).
        var targetLayout: KeyboardLayout
        var correctedWord: String
        let result = languageDetector.detect(keycodes: keycodes)
        switch result {
        case .switchTo(let layout, let word):
            targetLayout = layout
            correctedWord = word
        case .noSwitch:
            guard let other = layouts.first(where: { $0.id != currentLayout.id }) else { return false }
            targetLayout = other
            correctedWord = languageDetector.inputSourceManager.convertKeycodes(keycodes, toLayout: other)
            guard !correctedWord.isEmpty else { return false }
        }

        let originalWord = languageDetector.lastConvertedWord(keycodes: keycodes) ?? ""

        // Record for undo
        switchUndoManager.record(
            originalKeycodes: keycodes,
            originalWord: originalWord,
            correctedWord: correctedWord,
            originalLayoutID: currentLayout.id,
            targetLayoutID: targetLayout.id
        )

        isPaused = true
        lastCorrectionTime = CFAbsoluteTimeGetCurrent()
        let length = keycodes.count

        textReplacer.replaceCurrentWord(
            length: length,
            replacement: correctedWord,
            targetLayout: targetLayout,
            trailing: trailing
        ) { [weak self] in
            self?.isPaused = false
            self?.lastCorrectionTime = CFAbsoluteTimeGetCurrent()
        }

        buffer.clear()
        lastCompletedWord = nil
        DebugLog.shared.log("KM", "doubleShift via \(source): \(currentLayout.languageCode)→\(targetLayout.languageCode) len=\(length) trail=\(trailing ?? "∅")")
        return true
    }

    /// - Parameter trigger: the character the user just typed that caused us to
    ///                      consider the buffered word complete (space / `.` / `;`
    ///                      etc). It already landed in the text field, so the
    ///                      replacer must backspace over it and re-type it.
    ///                      Pass nil only if nothing was printed after the word.
    private func processCurrentWord(trigger: String?) {
        let keycodes = buffer.currentWord()
        // Require 3+ letters: 2-letter "words" (it/аа/oo) give too many false positives.
        guard keycodes.count >= 3 else {
            DebugLog.shared.log("KM", "word too short (len=\(keycodes.count))")
            return
        }

        let result = languageDetector.detect(keycodes: keycodes)
        let currentLang = languageDetector.inputSourceManager.currentLayout?.languageCode ?? "?"

        switch result {
        case .noSwitch:
            DebugLog.shared.log("KM", "detect: noSwitch len=\(keycodes.count) cur=\(currentLang)")
            if prefsService.isYoficatorEnabled { applyYoficator(keycodes: keycodes, trigger: trigger) }

        case .switchTo(let layout, var correctedWord):
            if exceptionsService.isWordExcepted(correctedWord) {
                DebugLog.shared.log("KM", "skip: word exception match")
                return
            }
            let originalWord = languageDetector.lastConvertedWord(keycodes: keycodes)
            if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
                DebugLog.shared.log("KM", "skip: auto-learned exception")
                return
            }

            if prefsService.isYoficatorEnabled && layout.isRussian {
                if let yo = yoficatorService.yoficate(correctedWord) { correctedWord = yo }
            }

            // Record for undo
            let currentLayoutID = languageDetector.inputSourceManager.currentLayout?.id ?? ""
            switchUndoManager.record(
                originalKeycodes: keycodes,
                originalWord: originalWord ?? "",
                correctedWord: correctedWord,
                originalLayoutID: currentLayoutID,
                targetLayoutID: layout.id
            )

            lastCorrectedOriginal = originalWord
            lastCorrectedReplacement = correctedWord
            backspaceCountAfterCorrection = 0

            isPaused = true
            lastCorrectionTime = CFAbsoluteTimeGetCurrent()

            textReplacer.replaceCurrentWord(
                length: keycodes.count,
                replacement: correctedWord,
                targetLayout: layout,
                trailing: trigger
            ) { [weak self] in
                self?.isPaused = false
                self?.lastCorrectionTime = CFAbsoluteTimeGetCurrent()
            }

            let fromLang = languageDetector.inputSourceManager.currentLayout?.languageCode ?? "?"
            DebugLog.shared.log("KM", "correction: \(fromLang)→\(layout.languageCode) len=\(keycodes.count) trig=\(trigger ?? "∅")")
            statsService.recordAutoSwitch()
            SoundService.shared.playSwitch(prefsService: prefsService)
            NotificationCenter.default.post(name: .statsUpdated, object: nil)
        }
    }

    private func applyYoficator(keycodes: [UInt16], trigger: String?) {
        guard let currentLayout = languageDetector.currentRussianLayout() else { return }
        let word = languageDetector.inputSourceManager.convertKeycodes(keycodes, toLayout: currentLayout)
        if let yo = yoficatorService.yoficate(word), yo != word {
            isPaused = true
            textReplacer.replaceCurrentWord(length: keycodes.count, replacement: yo, targetLayout: currentLayout, trailing: trigger) { [weak self] in
                self?.isPaused = false
            }
            statsService.recordTypoFix()
            NotificationCenter.default.post(name: .statsUpdated, object: nil)
        }
    }

    private func performUndo() {
        guard let correction = switchUndoManager.consume() else { return }
        guard let originalLayout = languageDetector.inputSourceManager.availableLayouts
                .first(where: { $0.id == correction.originalLayoutID }) else { return }

        isPaused = true
        textReplacer.replaceCurrentWord(
            length: correction.correctedWord.count,
            replacement: correction.originalWord,
            targetLayout: originalLayout
        ) { [weak self] in
            self?.isPaused = false
        }

        SoundService.shared.playSwitch(prefsService: prefsService)
        DebugLog.shared.log("KM", "undo applied")
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleEvent(proxy, type: type, event: event)
    return Unmanaged.passUnretained(event)
}
