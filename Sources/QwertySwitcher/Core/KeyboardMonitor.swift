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
    private let instantCorrectionAnalyzer: InstantCorrectionAnalyzer
    private var instantCorrectionGate = InstantCorrectionGate()
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
    private var pendingUserEvents = PendingUserEventQueue<QueuedUserEvent>()
    private var invalidateAfterReplacement = false
    // Set synchronously while handling a keydown we've decided to suppress
    // (its trigger races with our own backspaces — RC-1). Consumed exactly
    // once by the event tap callback right after `handleEvent` returns.
    private var suppressCurrentEvent = false

    private var autoLearnTracker = AutoLearnTracker()

    // Stale-buffer eviction: drop accumulated keys if user paused typing too long
    private var lastKeyTime: CFAbsoluteTime = 0
    private let staleBufferTimeout: CFAbsoluteTime = 10.0 // 10 sec idle → clear

    // Last completed word (for Double Shift fallback after space).
    // When user types "ghbdtn " and then hits Double Shift, the main buffer is
    // already empty — we pull keycodes from here instead.
    private var lastCompletedWord: (keystrokes: [BufferedKeystroke], trailing: String)?

    // Layout-dependent symbols typed with an empty letter buffer (leading
    // "$"/"#"/"@"/"/" etc., e.g. "$GRAF", "/model") belong to whichever word
    // starts right after them. Tracked SEPARATELY from `buffer` — which stays
    // letter-only so detect()/Double Shift/Yoficator scoring is completely
    // unaffected — and folded into the same backspace+retype transaction only
    // when a correction actually fires. Reset at every boundary/deletion/
    // context-invalidation so a stale run can never cause a wrong backspace
    // count. Trailing symbols (after the word, before the boundary) are left
    // out of scope for now — see Fix report.
    private var pendingLeadingSymbols: [BufferedKeystroke] = []

    private let spotlightBundleID = "com.apple.Spotlight"

    init(languageDetector: LanguageDetector, textReplacer: TextReplacer,
         statsService: StatisticsService, prefsService: PreferencesService,
         exceptionsService: ExceptionsService, yoficatorService: YoficatorService,
         switchUndoManager: SwitchUndoManager, perAppLayoutService: PerAppLayoutService,
         instantCorrectionAnalyzer: InstantCorrectionAnalyzer) {
        self.languageDetector = languageDetector
        self.textReplacer = textReplacer
        self.statsService = statsService
        self.prefsService = prefsService
        self.exceptionsService = exceptionsService
        self.yoficatorService = yoficatorService
        self.switchUndoManager = switchUndoManager
        self.perAppLayoutService = perAppLayoutService
        self.instantCorrectionAnalyzer = instantCorrectionAnalyzer

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutDidChange(_:)),
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

    @objc private func layoutDidChange(_ notification: Notification) {
        // A layout switch WE triggered (mid-correction, Double Shift, Undo)
        // must not wipe buffered word context — the distributed notification
        // can arrive 2-40ms after we already resumed, racing our own
        // completion handlers (RC-3). A manual/bot-driven switch still resets
        // context exactly as before (v0.2.0 feature).
        let selfInitiated = (notification.userInfo?[InputSourceManager.selfInitiatedKey] as? Bool) ?? false
        guard !selfInitiated else { return }
        buffer.clear()
        pendingLeadingSymbols.removeAll()
        lastCompletedWord = nil
        instantCorrectionGate.reset()
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
        pendingUserEvents.enqueue(QueuedUserEvent(type: event.type, event: event))
        return true
    }

    /// Read-and-reset the trigger-suppression flag. Called by the event tap
    /// callback exactly once, right after `handleEvent` returns, so it never
    /// leaks into an unrelated later event.
    fileprivate func consumeSuppressCurrentEvent() -> Bool {
        defer { suppressCurrentEvent = false }
        return suppressCurrentEvent
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
            DebugLog.shared.log(
                "KM",
                "event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) — re-enabling"
            )
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                health = secureInputDetector.isSecureInput ? .secureInput : .running
            } else {
                health = .unavailable
            }
            return
        }

        // Generated events carry a process-local marker. Unlike the old 300ms
        // cooldown, this filters only our own synthetic keystrokes (backspace/
        // retype) — replayed real keystrokes route as `.replayedUser` and are
        // analyzed exactly like live typing (RC-2: a replayed space must still
        // clear the buffer at a word boundary instead of bypassing analysis).
        if SyntheticEventMarker.route(event) == .ours { return }

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
            pendingLeadingSymbols.removeAll()
            lastCompletedWord = nil
            autoLearnTracker.cancel()
            health = .secureInput
            DebugLog.shared.log("KM", "skip: secure input")
            return
        }
        if health != .running { health = .running }

        // Stale buffer eviction — user paused typing too long, old keys don't belong to current word
        let now = CFAbsoluteTimeGetCurrent()
        if (!buffer.isEmpty || !pendingLeadingSymbols.isEmpty) && (now - lastKeyTime) > staleBufferTimeout {
            buffer.clear()
            pendingLeadingSymbols.removeAll()
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
            && LicenseService.shared.isEntitled
            && !exceptionsService.isCurrentAppExcepted()
            && !isSpotlight

        if InputBuffer.isDeleteKey(keycode) {
            switchUndoManager.invalidate()
            buffer.removeLast()
            lastCompletedWord = nil
            // Conservative: we can't tell from here whether the deleted
            // character was a letter or one of the tracked leading symbols,
            // so drop the run entirely rather than risk an over/under
            // backspace count on a later correction.
            pendingLeadingSymbols.removeAll()
            autoLearnTracker.registerDeletion()
            return
        }

        if InputBuffer.isWordBoundary(keycode) {
            let correctable = InputBuffer.isCorrectableBoundary(keycode)
            handleWordBoundary(
                trailing: correctable ? " " : nil,
                canAutoCorrect: canAutoCorrect && correctable,
                keepForManualSwitch: correctable,
                triggerEvent: event
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
                keepForManualSwitch: true,
                triggerEvent: event
            )
            return
        }

        if InputBuffer.isLetterKey(keycode) {
            switchUndoManager.invalidate()
            autoLearnTracker.registerNonDeletion()
            if buffer.isEmpty {
                lastCompletedWord = nil
                instantCorrectionGate.startNewWord()
            }
            buffer.append(keycode, flags: flags)
            if canAutoCorrect && prefsService.isInstantCorrectionEnabled && !instantCorrectionGate.wasCorrected {
                tryInstantCorrection(triggerEvent: event)
            }
        } else if InputBuffer.isNumberOrSpecial(keycode) {
            switchUndoManager.invalidate()
            guard !buffer.isEmpty else {
                // A layout-dependent symbol with no letters typed yet (leading
                // "$"/"#"/"@"/"/" etc.) belongs to whatever word starts right
                // after it — track it instead of treating it as the trailing
                // of an empty (uncorrectable) word, where it was structurally
                // unreachable for correction ("$GRAF", "/model").
                pendingLeadingSymbols.append(BufferedKeystroke(keycode: keycode, flags: flags))
                return
            }
            let digit = languageDetector.inputSourceManager.trailingCharacter(
                keycode: keycode, flags: flags
            ) ?? ""
            handleWordBoundary(
                trailing: digit,
                canAutoCorrect: canAutoCorrect,
                keepForManualSwitch: true,
                triggerEvent: event
            )
        } else {
            switchUndoManager.invalidate()
            autoLearnTracker.cancel()
            buffer.clear()
            pendingLeadingSymbols.removeAll()
            lastCompletedWord = nil
        }
    }

    private func handleWordBoundary(
        trailing: String?, canAutoCorrect: Bool, keepForManualSwitch: Bool, triggerEvent: CGEvent
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
            && processCurrentWord(trigger: trailing, triggerEvent: triggerEvent)

        if replacementStarted {
            lastCompletedWord = nil
        } else if keepForManualSwitch, !captured.isEmpty, let trailing {
            lastCompletedWord = (captured, trailing)
        } else {
            lastCompletedWord = nil
        }
        buffer.clear()
        pendingLeadingSymbols.removeAll()
    }

    /// Evaluate the word buffered so far for an instant (mid-word) correction.
    /// Unlike `processCurrentWord`, this runs on every buffered letter once the
    /// buffer reaches `InstantCorrectionAnalyzer.minLength` — no word boundary
    /// (space/punctuation) is required. On success the active input source is
    /// switched immediately so the rest of the word types correctly, and
    /// `InstantCorrectionGate` is marked so the eventual boundary handler does
    /// not attempt a second correction on the same word.
    private func tryInstantCorrection(triggerEvent: CGEvent) {
        guard !isPaused else { return }
        let keystrokes = buffer.currentWord()
        guard keystrokes.count >= InstantCorrectionAnalyzer.minLength else { return }
        guard let currentLayout = languageDetector.inputSourceManager.currentLayout else { return }
        let layouts = languageDetector.activeLayouts
        guard layouts.count >= 2, layouts.contains(where: { $0.id == currentLayout.id }) else { return }
        let otherLayouts = layouts.filter { $0.id != currentLayout.id }

        guard let result = instantCorrectionAnalyzer.evaluate(
            keystrokes: keystrokes,
            currentLayout: currentLayout,
            otherLayouts: otherLayouts,
            convert: { [languageDetector] layout in
                languageDetector.inputSourceManager.convertKeystrokes(keystrokes, toLayout: layout)
            }
        ) else { return }

        if exceptionsService.isWordExcepted(result.correctedWord) {
            DebugLog.shared.log("KM", "instant skip: word exception match")
            return
        }
        let originalWord = languageDetector.lastConvertedWord(keystrokes: keystrokes)
        if let orig = originalWord, exceptionsService.isAutoLearned(orig) {
            DebugLog.shared.log("KM", "instant skip: auto-learned exception")
            return
        }

        var correctedWord = result.correctedWord
        if prefsService.isYoficatorEnabled && result.layout.isRussian {
            if let yo = yoficatorService.yoficate(correctedWord) { correctedWord = yo }
        }

        isPaused = true
        instantCorrectionGate.markCorrected()
        // Same leading-symbol fold-in as the boundary path (processCurrentWord):
        // a "$"/"#"/"@"/"/" typed right before this word is on screen in the
        // CURRENT (wrong) layout already — reconvert it together with the
        // word instead of leaving it stuck in whatever rendered it.
        let leadingSymbols = pendingLeadingSymbols
        let leadingOriginalText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: currentLayout)
        let leadingCorrectedText = leadingSymbols.isEmpty ? ""
            : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: result.layout)
        let runReplacement = leadingCorrectedText + correctedWord
        // The triggering letter is already in `keystrokes` (appended by
        // handleEvent just before this call) but has NOT reached the app yet
        // — headInsert tap runs before delivery. Suppress it so it can never
        // race our own backspaces (RC-1): only `keystrokes.count - 1` letters
        // are actually on screen (plus any leading symbols, which WERE
        // delivered normally); `correctedWord` already accounts for the
        // suppressed one.
        suppressCurrentEvent = true
        pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
        let length = leadingSymbols.count + keystrokes.count - 1
        textReplacer.replaceCurrentWord(
            length: length,
            replacement: runReplacement,
            targetLayout: result.layout,
            trailing: nil
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.pendingUserEvents.discardFront()
                let original = originalWord ?? ""
                self.switchUndoManager.record(
                    originalKeycodes: leadingSymbols.map(\.keycode) + keystrokes.map(\.keycode),
                    originalWord: leadingOriginalText + original,
                    correctedWord: runReplacement,
                    trailing: nil,
                    originalLayoutID: currentLayout.id,
                    targetLayoutID: result.layout.id
                )
                if !original.isEmpty {
                    self.autoLearnTracker.recordCorrection(
                        original: original, corrected: correctedWord, trailing: nil
                    )
                }
                self.statsService.recordAutoSwitch()
                SoundService.shared.playSwitch(prefsService: self.prefsService)
                NotificationCenter.default.post(name: .statsUpdated, object: nil)
                DebugLog.shared.log(
                    "KM",
                    "instant correction: \(currentLayout.languageCode)→\(result.layout.languageCode)"
                        + " len=\(length) lead=\(leadingSymbols.count)"
                )
            case .layoutSwitchFailed:
                self.instantCorrectionGate.reset()
                DebugLog.shared.log("KM", "instant correction aborted: layout switch verification failed")
            case .cancelled:
                DebugLog.shared.log("KM", "instant correction cancelled: editing context changed")
            }
            self.finishReplacement()
        }
    }

    private func invalidateEditingContext() {
        if isPaused {
            invalidateAfterReplacement = true
            textReplacer.cancelCurrentReplacement()
            return
        }
        buffer.clear()
        pendingLeadingSymbols.removeAll()
        lastCompletedWord = nil
        autoLearnTracker.cancel()
        switchUndoManager.invalidate()
        instantCorrectionGate.reset()
        languageDetector.resetContext()
    }

    /// Try to swap the last word currently sitting in the input buffer.
    /// Returns true if a correction was applied. Called from Double Shift hotkey.
    @discardableResult
    func swapLastWordInBuffer() -> Bool {
        guard !isPaused, LicenseService.shared.isEntitled else { return false }
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
    private func processCurrentWord(trigger: String?, triggerEvent: CGEvent) -> Bool {
        guard !isPaused else { return false }
        if instantCorrectionGate.consumeIfCorrected() {
            DebugLog.shared.log("KM", "skip boundary correction: already instant-corrected")
            return false
        }
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

            // Layout-dependent symbols typed right before this word (e.g. "$"
            // in "$GRAF", "/" in "/model") were structurally unreachable for
            // correction before — fold them into the SAME backspace+retype
            // transaction so they're rendered in the TARGET layout too,
            // instead of being left in whatever (possibly wrong) layout
            // rendered them originally. The letter-only `keystrokes` above are
            // what `detect()` scored — this never changes that calibration.
            let leadingSymbols = pendingLeadingSymbols
            let runLength = leadingSymbols.count + keystrokes.count
            let leadingOriginalText = leadingSymbols.isEmpty ? ""
                : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: sourceLayout)
            let leadingCorrectedText = leadingSymbols.isEmpty ? ""
                : languageDetector.inputSourceManager.convertKeystrokes(leadingSymbols, toLayout: layout)
            let runReplacement = leadingCorrectedText + correctedWord

            // The word itself is already on screen (typed letter-by-letter
            // normally), but the trigger that just completed it (space/
            // punctuation) hasn't been delivered yet — headInsert tap runs
            // before delivery. Suppress it so it can never race our own
            // backspaces (RC-1); it's retyped as part of the payload instead.
            isPaused = true
            suppressCurrentEvent = true
            pendingUserEvents.enqueueFront(QueuedUserEvent(type: .keyDown, event: triggerEvent))
            textReplacer.replaceCurrentWord(
                length: runLength,
                replacement: runReplacement,
                targetLayout: layout,
                trailing: trigger,
                trailingAlreadyOnScreen: false
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.pendingUserEvents.discardFront()
                    let original = originalWord ?? ""
                    self.switchUndoManager.record(
                        originalKeycodes: leadingSymbols.map(\.keycode) + keystrokes.map(\.keycode),
                        originalWord: leadingOriginalText + original,
                        correctedWord: runReplacement,
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
                        "correction: \(sourceLayout.languageCode)→\(layout.languageCode)"
                            + " len=\(runLength) lead=\(leadingSymbols.count) trig=\(trigger ?? "∅")"
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
        for queued in pendingUserEvents.drain() {
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
    if !isDisableNotification && SyntheticEventMarker.route(event) == .ours {
        return Unmanaged.passUnretained(event)
    }
    if !isDisableNotification && monitor.queueIfReplacementActive(event) { return nil }
    let suppressHandledShortcut = monitor.handlesShortcut(type: type, event: event)
    monitor.handleEvent(proxy, type: type, event: event)
    let suppressTrigger = monitor.consumeSuppressCurrentEvent()
    return (suppressHandledShortcut || suppressTrigger) ? nil : Unmanaged.passUnretained(event)
}
