import Foundation
import CoreGraphics
import AppKit

final class KeyboardMonitor {
    private struct QueuedUserEvent {
        let type: CGEventType
        let keycode: CGKeyCode
        let flags: CGEventFlags
        let autorepeat: Int64
        let keyboardType: Int64

        init(type: CGEventType, event: CGEvent) {
            self.type = type
            keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            flags = event.flags
            autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            keyboardType = event.getIntegerValueField(.keyboardEventKeyboardType)
        }

        func makeEvent() -> CGEvent? {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keycode,
                keyDown: type != .keyUp
            ) else { return nil }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            SyntheticEventMarker.markAsReplayedUserEvent(event)
            return event
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
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
    private let permissionsService = PermissionsService()
    var hotkeyManager: HotkeyManager?
    private(set) var isRunning = false
    private(set) var health: EventTapHealth = .stopped {
        didSet {
            guard health != oldValue else { return }
            NotificationCenter.default.post(name: .eventTapHealthChanged, object: self)
        }
    }
    var isPaused = false
    private var pendingUserEvents: [QueuedUserEvent] = []
    private var invalidateAfterReplacement = false

    private var autoLearnTracker = AutoLearnTracker()

    // Stale-buffer eviction: drop accumulated keys if user paused typing too long
    private var lastKeyTime: CFAbsoluteTime = 0
    private let staleBufferTimeout: CFAbsoluteTime = 10.0 // 10 sec idle → clear

    // Last completed word (for Double Shift fallback after space).
    // When user types "ghbdtn " and then hits Double Shift, the main buffer is
    // already empty — we pull keycodes from here instead.
    private var lastCompletedWord: (keystrokes: [BufferedKeystroke], trailing: String)?

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
        invalidateEditingContext()
    }

    @objc private func layoutDidChange() {
        buffer.clear()
        lastCompletedWord = nil
        languageDetector.resetContext()
    }

    func start() {
        guard eventTap == nil else { return }
        guard permissionsService.hasAllPermissions else {
            health = .missingPermissions
            return
        }
        health = .starting

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        )

        guard let tap = eventTap else {
            NSLog("[KeyboardMonitor] Failed to create event tap")
            DebugLog.shared.log("KM", "ERROR: failed to create CGEventTap (check permissions)")
            health = .unavailable
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.invalidateEditingContext()
                }
            }
        }
        health = secureInputDetector.isSecureInput ? .secureInput : .running
        NSLog("[KeyboardMonitor] Started")
        DebugLog.shared.log("KM", "event tap started")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        isRunning = false
        health = .stopped
    }

    /// Polling entry point used by AppDelegate. It makes permission grants and
    /// event-tap recovery take effect without requiring an application restart.
    func refreshHealth() {
        guard permissionsService.hasAllPermissions else {
            if eventTap != nil { stop() }
            health = .missingPermissions
            return
        }
        guard let tap = eventTap else {
            start()
            return
        }
        if !CFMachPortIsValid(tap) {
            DebugLog.shared.log("KM", "event tap invalidated — restarting")
            stop()
            start()
            return
        }
        health = secureInputDetector.isSecureInput ? .secureInput : .running
    }

    // MARK: - Event Handling

    fileprivate func queueIfReplacementActive(_ event: CGEvent) -> Bool {
        guard isPaused, !SyntheticEventMarker.shouldBypass(event) else { return false }
        pendingUserEvents.append(QueuedUserEvent(type: event.type, event: event))
        return true
    }

    fileprivate func handlesShortcut(type: CGEventType, event: CGEvent) -> Bool {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged && keycode == 57 {
            return prefsService.isCapsLockSwitchEnabled
        }
        guard type == .keyDown else { return false }
        let flags = event.flags
        if flags.contains(.maskCommand) && flags.contains(.maskShift) && keycode == 9 {
            return prefsService.isPasteNoFormatEnabled
                && NSPasteboard.general.string(forType: .string) != nil
        }
        return flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
            && keycode == 6
            && switchUndoManager.canUndo
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                health = secureInputDetector.isSecureInput ? .secureInput : .running
            } else {
                health = .unavailable
            }
            return
        }

        // Generated events carry a process-local marker. Unlike the old 300ms
        // cooldown, this filters only our own keystrokes and never drops real
        // user input typed immediately after a correction.
        if SyntheticEventMarker.shouldBypass(event) { return }

        if type == .flagsChanged {
            hotkeyManager?.handleFlagsChanged(event)
            return
        }

        guard type == .keyDown else { return }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Cmd+Shift+V
        if flags.contains(.maskCommand) && flags.contains(.maskShift) && keycode == 9 {
            if prefsService.isPasteNoFormatEnabled {
                isPaused = true
                let started = hotkeyManager?.handlePasteNoFormat { [weak self] in
                    self?.finishReplacement()
                } ?? false
                if !started { isPaused = false }
            }
            return
        }

        // Cmd+Option+Z → undo last switch
        // (Plain Cmd+Z is left to the host app to avoid conflicting with its own undo stack.)
        if flags.contains(.maskCommand) && flags.contains(.maskAlternate)
            && keycode == 6 && switchUndoManager.canUndo {
            _ = undoLastCorrection()
            return
        }

        hotkeyManager?.markKeyPressed()
        perAppLayoutService.rememberCurrentLayout()

        // Secure fields are never buffered, including while auto-switch is off.
        if secureInputDetector.isSecureInput {
            buffer.clear()
            lastCompletedWord = nil
            autoLearnTracker.cancel()
            health = .secureInput
            DebugLog.shared.log("KM", "skip: secure input")
            return
        }
        if health != .running { health = .running }

        // Stale buffer eviction — user paused typing too long, old keys don't belong to current word
        let now = CFAbsoluteTimeGetCurrent()
        if !buffer.isEmpty && (now - lastKeyTime) > staleBufferTimeout {
            buffer.clear()
        }
        lastKeyTime = now

        let isSpotlight = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == spotlightBundleID
        if InputBuffer.isModifierActive(flags) {
            if InputBuffer.shouldInvalidateEditingContext(forModifiedFlags: flags) {
                invalidateEditingContext()
            }
            return
        }
        let canAutoCorrect = prefsService.isAutoSwitchEnabled
            && !exceptionsService.isCurrentAppExcepted()
            && !isSpotlight

        if InputBuffer.isDeleteKey(keycode) {
            switchUndoManager.invalidate()
            buffer.removeLast()
            lastCompletedWord = nil
            autoLearnTracker.registerDeletion()
            return
        }

        if InputBuffer.isWordBoundary(keycode) {
            let correctable = InputBuffer.isCorrectableBoundary(keycode)
            handleWordBoundary(
                trailing: correctable ? " " : nil,
                canAutoCorrect: canAutoCorrect && correctable,
                keepForManualSwitch: correctable
            )
            return
        }

        // Context-aware punctuation: e.g. `.` `,` `;` `'` produce real letters in
        // Russian layout (ю, б, ж, э) but punctuation in English. Treat them as a
        // word boundary only when current layout is Latin.
        let currentLayout = languageDetector.inputSourceManager.currentLayout
        let currentLang = currentLayout?.languageCode
        if InputBuffer.isPunctuationIn(keycode: keycode, languageCode: currentLang, flags: flags) {
            let punctChar = currentLayout.flatMap {
                languageDetector.inputSourceManager.characterForKeycode(
                    keycode, layout: $0, flags: flags
                )
            } ?? InputBuffer.punctuationChar(
                keycode: keycode, languageCode: currentLang, flags: flags
            ) ?? ""
            handleWordBoundary(
                trailing: punctChar,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true
            )
            return
        }

        if InputBuffer.isLetterKey(keycode) {
            switchUndoManager.invalidate()
            autoLearnTracker.registerNonDeletion()
            if buffer.isEmpty { lastCompletedWord = nil }
            buffer.append(keycode, flags: flags)
        } else if InputBuffer.isNumberOrSpecial(keycode) {
            switchUndoManager.invalidate()
            let digit = languageDetector.inputSourceManager.trailingCharacter(
                keycode: keycode, flags: flags
            ) ?? ""
            handleWordBoundary(
                trailing: digit,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true
            )
        } else {
            switchUndoManager.invalidate()
            autoLearnTracker.cancel()
            buffer.clear()
            lastCompletedWord = nil
        }
    }

    private func handleWordBoundary(
        trailing: String?, canAutoCorrect: Bool, keepForManualSwitch: Bool
    ) {
        let captured = buffer.currentWord()
        if captured.isEmpty { switchUndoManager.invalidate() }
        let retyped = languageDetector.lastConvertedWord(keystrokes: captured) ?? ""
        let learned = autoLearnTracker.confirmRetype(word: retyped, trailing: trailing)
        if let learned {
            exceptionsService.learnException(
                original: learned.original,
                corrected: learned.corrected
            )
            DebugLog.shared.log("AUTOLEARN", "exact retype confirmed")
        }

        let replacementStarted = canAutoCorrect
            && learned == nil
            && !captured.isEmpty
            && processCurrentWord(trigger: trailing)

        if replacementStarted {
            lastCompletedWord = nil
        } else if keepForManualSwitch, !captured.isEmpty, let trailing {
            lastCompletedWord = (captured, trailing)
        } else {
            lastCompletedWord = nil
        }
        buffer.clear()
    }

    private func invalidateEditingContext() {
        if isPaused {
            invalidateAfterReplacement = true
            textReplacer.cancelCurrentReplacement()
            return
        }
        buffer.clear()
        lastCompletedWord = nil
        autoLearnTracker.cancel()
        switchUndoManager.invalidate()
        languageDetector.resetContext()
    }

    /// Try to swap the last word currently sitting in the input buffer.
    /// Returns true if a correction was applied. Called from Double Shift hotkey.
    @discardableResult
    func swapLastWordInBuffer() -> Bool {
        guard !isPaused else { return false }
        var keystrokes = buffer.currentWord()
        var trailing: String? = nil
        var source = "buffer"

        // Fallback: buffer was cleared by a trailing space/punct — use the
        // history slot we captured at the word boundary. No TTL: as long as
        // the word hasn't been replaced by a new one, Double Shift must work.
        // History is invalidated only when a new word starts or after a
        // successful conversion (line below this function).
        if keystrokes.count < 2 {
            if let last = lastCompletedWord, last.keystrokes.count >= 2 {
                keystrokes = last.keystrokes
                trailing = last.trailing
                source = "history"
            }
        }

        guard keystrokes.count >= 2 else { return false }

        let layouts = languageDetector.activeLayouts
        guard layouts.count >= 2,
              let currentLayout = languageDetector.inputSourceManager.currentLayout,
              layouts.contains(where: { $0.id == currentLayout.id }) else { return false }

        // Decide target: if detector finds a valid other layout, use it.
        // Otherwise fall back to "the other layout" (force swap).
        var targetLayout: KeyboardLayout
        var correctedWord: String
        let result = languageDetector.detect(keystrokes: keystrokes)
        switch result {
        case .switchTo(let layout, let word):
            targetLayout = layout
            correctedWord = word
        case .noSwitch:
            guard let other = layouts.first(where: { $0.id != currentLayout.id }) else { return false }
            targetLayout = other
            correctedWord = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: other)
            guard !correctedWord.isEmpty else { return false }
        }

        let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes) ?? ""

        isPaused = true
        let length = keystrokes.count

        textReplacer.replaceCurrentWord(
            length: length,
            replacement: correctedWord,
            targetLayout: targetLayout,
            trailing: trailing
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.switchUndoManager.record(
                    originalKeycodes: keystrokes.map(\.keycode),
                    originalWord: originalWord,
                    correctedWord: correctedWord,
                    trailing: trailing,
                    originalLayoutID: currentLayout.id,
                    targetLayoutID: targetLayout.id
                )
                self.buffer.clear()
                self.lastCompletedWord = nil
                self.statsService.recordOptionSwitch()
                SoundService.shared.playSwitch(prefsService: self.prefsService)
                NotificationCenter.default.post(name: .statsUpdated, object: nil)
                DebugLog.shared.log(
                    "KM",
                    "doubleShift via \(source): \(currentLayout.languageCode)→\(targetLayout.languageCode) len=\(length) trail=\(trailing ?? "∅")"
                )
            case .layoutSwitchFailed:
                DebugLog.shared.log("KM", "doubleShift aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "doubleShift cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    /// - Parameter trigger: the character the user just typed that caused us to
    ///                      consider the buffered word complete (space / `.` / `;`
    ///                      etc). It already landed in the text field, so the
    ///                      replacer must backspace over it and re-type it.
    ///                      Pass nil only if nothing was printed after the word.
    @discardableResult
    private func processCurrentWord(trigger: String?) -> Bool {
        guard !isPaused else { return false }
        let keystrokes = buffer.currentWord()
        // Require 3+ letters: 2-letter "words" (it/аа/oo) give too many false positives.
        guard keystrokes.count >= 3 else {
            DebugLog.shared.log("KM", "word too short (len=\(keystrokes.count))")
            return false
        }

        let result = languageDetector.detect(keystrokes: keystrokes)
        let currentLang = languageDetector.inputSourceManager.currentLayout?.languageCode ?? "?"

        switch result {
        case .noSwitch:
            DebugLog.shared.log("KM", "detect: noSwitch len=\(keystrokes.count) cur=\(currentLang)")
            if prefsService.isYoficatorEnabled {
                return applyYoficator(keystrokes: keystrokes, trigger: trigger)
            }
            return false

        case .switchTo(let layout, var correctedWord):
            if exceptionsService.isWordExcepted(correctedWord) {
                DebugLog.shared.log("KM", "skip: word exception match")
                return false
            }
            let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes)
            if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
                DebugLog.shared.log("KM", "skip: auto-learned exception")
                return false
            }

            if prefsService.isYoficatorEnabled && layout.isRussian {
                if let yo = yoficatorService.yoficate(correctedWord) { correctedWord = yo }
            }

            guard let sourceLayout = languageDetector.inputSourceManager.currentLayout else {
                return false
            }

            isPaused = true
            textReplacer.replaceCurrentWord(
                length: keystrokes.count,
                replacement: correctedWord,
                targetLayout: layout,
                trailing: trigger
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    let original = originalWord ?? ""
                    self.switchUndoManager.record(
                        originalKeycodes: keystrokes.map(\.keycode),
                        originalWord: original,
                        correctedWord: correctedWord,
                        trailing: trigger,
                        originalLayoutID: sourceLayout.id,
                        targetLayoutID: layout.id
                    )
                    if !original.isEmpty {
                        self.autoLearnTracker.recordCorrection(
                            original: original,
                            corrected: correctedWord,
                            trailing: trigger
                        )
                    }
                    self.statsService.recordAutoSwitch()
                    SoundService.shared.playSwitch(prefsService: self.prefsService)
                    NotificationCenter.default.post(name: .statsUpdated, object: nil)
                    DebugLog.shared.log(
                        "KM",
                        "correction: \(sourceLayout.languageCode)→\(layout.languageCode) len=\(keystrokes.count) trig=\(trigger ?? "∅")"
                    )
                case .layoutSwitchFailed:
                    if let trigger {
                        self.lastCompletedWord = (keystrokes, trigger)
                    }
                    DebugLog.shared.log("KM", "correction aborted: layout switch verification failed")
                case .cancelled:
                    DebugLog.shared.log("KM", "correction cancelled: editing context changed")
                }
                self.finishReplacement()
            }
            return true
        }
    }

    @discardableResult
    private func applyYoficator(keystrokes: [BufferedKeystroke], trigger: String?) -> Bool {
        guard let currentLayout = languageDetector.currentRussianLayout() else { return false }
        let word = languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: currentLayout)
        if let yo = yoficatorService.yoficate(word), yo != word {
            isPaused = true
            textReplacer.replaceCurrentWord(
                length: keystrokes.count,
                replacement: yo,
                targetLayout: currentLayout,
                trailing: trigger
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.switchUndoManager.record(
                        originalKeycodes: keystrokes.map(\.keycode),
                        originalWord: word,
                        correctedWord: yo,
                        trailing: trigger,
                        originalLayoutID: currentLayout.id,
                        targetLayoutID: currentLayout.id
                    )
                    self.statsService.recordTypoFix()
                    NotificationCenter.default.post(name: .statsUpdated, object: nil)
                case .layoutSwitchFailed:
                    DebugLog.shared.log("KM", "yoficator aborted: layout switch verification failed")
                case .cancelled:
                    DebugLog.shared.log("KM", "yoficator cancelled: editing context changed")
                }
                self.finishReplacement()
            }
            return true
        }
        return false
    }

    @discardableResult
    func undoLastCorrection() -> Bool {
        guard !isPaused else { return false }
        guard let correction = switchUndoManager.lastCorrection else { return false }
        guard let originalLayout = languageDetector.inputSourceManager.layout(
            withID: correction.originalLayoutID
        ) else { return false }
        _ = switchUndoManager.consume()

        isPaused = true
        textReplacer.replaceCurrentWord(
            length: correction.correctedWord.count,
            replacement: correction.originalWord,
            targetLayout: originalLayout,
            trailing: correction.trailing
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.buffer.clear()
                self.lastCompletedWord = nil
                self.autoLearnTracker.cancel()
                SoundService.shared.playSwitch(prefsService: self.prefsService)
                DebugLog.shared.log("KM", "undo applied with trailing preserved")
            case .layoutSwitchFailed:
                self.switchUndoManager.record(
                    originalKeycodes: correction.originalKeycodes,
                    originalWord: correction.originalWord,
                    correctedWord: correction.correctedWord,
                    trailing: correction.trailing,
                    originalLayoutID: correction.originalLayoutID,
                    targetLayoutID: correction.targetLayoutID
                )
                DebugLog.shared.log("KM", "undo aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "undo cancelled: editing context changed")
            }
            self.finishReplacement()
        }
        return true
    }

    private func finishReplacement() {
        isPaused = false
        if invalidateAfterReplacement {
            invalidateAfterReplacement = false
            invalidateEditingContext()
        }
        let events = pendingUserEvents
        pendingUserEvents.removeAll(keepingCapacity: true)
        for queued in events {
            guard let event = queued.makeEvent() else { continue }
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let isDisableNotification = type == .tapDisabledByTimeout
        || type == .tapDisabledByUserInput
    if !isDisableNotification && SyntheticEventMarker.shouldBypass(event) {
        return Unmanaged.passUnretained(event)
    }
    if !isDisableNotification && monitor.queueIfReplacementActive(event) { return nil }
    let suppressHandledShortcut = monitor.handlesShortcut(type: type, event: event)
    monitor.handleEvent(proxy, type: type, event: event)
    return suppressHandledShortcut ? nil : Unmanaged.passUnretained(event)
}
