import Foundation
import Carbon

extension Notification.Name {
    static let layoutChanged = Notification.Name(AppIdentity.keyPrefix + "layoutChanged")
}

final class InputSourceManager {
    /// userInfo key on `.layoutChanged` — true when the switch was caused by
    /// our own `switchTo` call (mid-correction, Double Shift, Undo), false for
    /// a manual/bot-driven switch. See `isSelfInitiated`.
    static let selfInitiatedKey = "selfInitiated"

    private(set) var availableLayouts: [KeyboardLayout] = []
    private var layoutsByID: [String: KeyboardLayout] = [:]
    // Recorded synchronously BEFORE calling TISSelectInputSource so it is
    // already set no matter how quickly the distributed notification below
    // fires (observed 2-40ms delay — RC-3).
    private var pendingSelfSwitchID: String?

    // Test isolation (incident 05.08.2026): `switchTo` calls
    // `TISSelectInputSource`, which changes the Mac's REAL active keyboard
    // layout process-wide — it isn't scoped to whichever binary called it.
    // The test suite drives a real `KeyboardMonitor` through dozens of ru/en
    // switches (`KeyboardMonitorIntegrationTests` and friends), and a live
    // test run mid-typing corrupted the owner's actual input
    // (`~/Library/Logs/QwertySwitcher/debug.log`, 07:50:23–07:50:29 — "даже"
    // typed as "дfже"). Tied directly to the `--test` launch argument
    // (already how `main.swift` picks the headless test path) rather than to
    // an env var someone could forget to export — a plain `--test` run is
    // ALWAYS safe by default, with no cooperation required from
    // `Scripts/test.sh`. While simulated, `switchTo` records the target in
    // `simulatedLayoutID` instead of calling TIS, and `currentLayout` reads
    // that simulated value back — so the whole detect/correct/verify flow
    // behaves exactly as it always did (same read-after-write it relies on),
    // just without ever touching the real system layout. A normal (non
    // `--test`) launch is completely unaffected — production always
    // switches for real.
    private static var isTestBinary: Bool {
        CommandLine.arguments.contains("--test")
    }
    /// Explicit, rare escape hatch for a manual full-fidelity run that
    /// deliberately wants the real TIS integration exercised — OFF by
    /// default, and `TestRunner.run()` prints a loud warning when it's set.
    private static var realLayoutSwitchOptedIn: Bool {
        ProcessInfo.processInfo.environment["QSW_ALLOW_REAL_LAYOUT_SWITCH"] == "1"
    }
    private static var layoutSwitchingIsSimulated: Bool {
        isTestBinary && !realLayoutSwitchOptedIn
    }
    /// Read by `TestRunner.run()` to print the warning banner mentioned above.
    static var isTestBinaryWithRealLayoutSwitchEnabled: Bool {
        isTestBinary && realLayoutSwitchOptedIn
    }
    private var simulatedLayoutID: String?

    init() {
        reloadLayouts()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var currentLayout: KeyboardLayout? {
        if Self.layoutSwitchingIsSimulated, let simulatedLayoutID {
            return layoutsByID[simulatedLayoutID]
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = getSourceID(source) else { return nil }
        return layoutsByID[id]
    }

    /// The detector currently has validated language models only for English and Russian.
    /// Other installed layouts remain available to macOS, but are never guessed as English.
    var supportedLayouts: [KeyboardLayout] {
        availableLayouts.filter { $0.languageCode == "en" || $0.languageCode == "ru" }
    }

    func layout(withID id: String) -> KeyboardLayout? {
        layoutsByID[id]
    }

    func resolvedActiveLayouts(preferredIDs: [String]) -> [KeyboardLayout] {
        var selected: [KeyboardLayout] = []
        for id in preferredIDs {
            guard let layout = layoutsByID[id], supportedLayouts.contains(where: { $0.id == id }) else {
                continue
            }
            guard !selected.contains(where: { $0.languageCode == layout.languageCode }) else { continue }
            selected.append(layout)
        }

        if let current = currentLayout,
           supportedLayouts.contains(where: { $0.id == current.id }),
           !selected.contains(where: { $0.languageCode == current.languageCode }) {
            selected.append(current)
        }

        for language in ["en", "ru"] where selected.count < 2 {
            if let layout = supportedLayouts.first(where: { $0.languageCode == language }),
               !selected.contains(where: { $0.languageCode == language }) {
                selected.append(layout)
            }
        }
        return Array(selected.prefix(2))
    }

    @discardableResult
    func switchTo(_ layout: KeyboardLayout) -> Bool {
        if Self.layoutSwitchingIsSimulated {
            simulatedLayoutID = layout.id
            return true
        }
        pendingSelfSwitchID = layout.id
        let status = TISSelectInputSource(layout.source)
        if status != noErr {
            NSLog("[InputSource] Failed to switch to \(layout.name): status=\(status)")
            pendingSelfSwitchID = nil
            return false
        }
        return true
    }

    /// Selects and verifies a layout before any destructive text replacement starts.
    /// Must be called on the main thread because TIS notifications and AppKit state live there.
    func switchToAndVerify(_ layout: KeyboardLayout, maxAttempts: Int = 3) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if currentLayout?.id == layout.id { return true }

        for attempt in 0..<max(1, maxAttempts) {
            guard switchTo(layout) else { continue }
            if currentLayout?.id == layout.id { return true }
            if attempt + 1 < maxAttempts { Thread.sleep(forTimeInterval: 0.008) }
        }
        DebugLog.shared.log("IS", "layout verification failed target=\(layout.languageCode)")
        return false
    }

    func characterForKeycode(_ keycode: UInt16, layout: KeyboardLayout,
                             flags: CGEventFlags = []) -> String? {
        guard let layoutPtr = TISGetInputSourceProperty(layout.source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return nil }
            let kbLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var actualLength: Int = 0

            var carbonModifiers: UInt32 = 0
            if flags.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }
            if flags.contains(.maskAlphaShift) { carbonModifiers |= UInt32(alphaLock) }

            UCKeyTranslate(kbLayout, keycode, UInt16(kUCKeyActionDown),
                           carbonModifiers >> 8,
                           UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeyState, chars.count, &actualLength, &chars)

            guard actualLength > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualLength)
        }
    }

    func trailingCharacter(keycode: UInt16, layout: KeyboardLayout? = nil,
                           flags: CGEventFlags = []) -> String? {
        if let resolvedLayout = layout ?? currentLayout,
           let character = characterForKeycode(keycode, layout: resolvedLayout, flags: flags),
           !character.isEmpty {
            return character
        }
        return InputBuffer.digitChar(keycode: keycode, flags: flags)
    }

    func convertKeycodes(_ keycodes: [UInt16], toLayout layout: KeyboardLayout) -> String {
        convertKeystrokes(keycodes.map { BufferedKeystroke(keycode: $0, flags: []) }, toLayout: layout)
    }

    func convertKeystrokes(_ keystrokes: [BufferedKeystroke], toLayout layout: KeyboardLayout) -> String {
        var result = ""
        for stroke in keystrokes {
            if let ch = characterForKeycode(stroke.keycode, layout: layout, flags: stroke.flags) {
                result += ch
            }
        }
        return result
    }

    // MARK: - Private

    private func reloadLayouts() {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        availableLayouts = sources.compactMap { source in
            guard let catPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { return nil }
            let cat = Unmanaged<CFString>.fromOpaque(catPtr).takeUnretainedValue() as String
            guard cat == (kTISCategoryKeyboardInputSource as String) else { return nil }

            guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
            let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
            guard type == (kTISTypeKeyboardLayout as String) else { return nil }

            guard let id = getSourceID(source), let name = getSourceName(source) else { return nil }
            let lang = Self.inferredLanguage(
                sourceID: id,
                languages: getSourceLanguages(source)
            )

            return KeyboardLayout(id: id, name: name, source: source, languageCode: lang)
        }

        layoutsByID = Dictionary(uniqueKeysWithValues: availableLayouts.map { ($0.id, $0) })
    }

    private func getSourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func getSourceName(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func getSourceLanguages(_ source: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        let values = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        return values ?? []
    }

    static func inferredLanguage(sourceID: String, languages: [String]) -> String {
        for language in languages {
            let code = Locale(identifier: language).language.languageCode?.identifier
                ?? language.split(separator: "-").first.map(String.init)
                ?? language
            if code == "en" || code == "ru" { return code }
            if !code.isEmpty { return code }
        }
        let lowered = sourceID.lowercased()
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if tokens.contains("russian") { return "ru" }
        if tokens.contains("ukrainian") { return "uk" }
        if tokens.contains("german") { return "de" }
        if tokens.contains("french") { return "fr" }
        if tokens.contains("abc") || tokens.contains("us") || tokens.contains("british") {
            return "en"
        }
        return "und"
    }

    @objc private func inputSourceChanged() {
        reloadLayouts()
        let layoutName = currentLayout?.name ?? "?"
        let lang = currentLayout?.languageCode ?? "?"
        let selfInitiated = Self.isSelfInitiated(
            pendingSelfSwitchID: pendingSelfSwitchID, newLayoutID: currentLayout?.id
        )
        pendingSelfSwitchID = nil
        DebugLog.shared.log(
            "IS", "layout changed → \(lang):\(layoutName)\(selfInitiated ? " (self)" : "")"
        )
        NotificationCenter.default.post(
            name: .layoutChanged, object: nil,
            userInfo: [Self.selfInitiatedKey: selfInitiated]
        )
    }

    /// Pure decision extracted for testability: was this input-source-changed
    /// notification caused by our own pending `switchTo` call?
    static func isSelfInitiated(pendingSelfSwitchID: String?, newLayoutID: String?) -> Bool {
        pendingSelfSwitchID != nil && pendingSelfSwitchID == newLayoutID
    }
}
