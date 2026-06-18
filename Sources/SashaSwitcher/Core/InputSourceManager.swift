import Foundation
import Carbon

extension Notification.Name {
    static let layoutChanged = Notification.Name("tech.sasha.switcher.layoutChanged")
}

final class InputSourceManager {
    private(set) var availableLayouts: [KeyboardLayout] = []
    private var layoutsByID: [String: KeyboardLayout] = [:]

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
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = getSourceID(source) else { return nil }
        return layoutsByID[id]
    }

    @discardableResult
    func switchTo(_ layout: KeyboardLayout) -> Bool {
        let status = TISSelectInputSource(layout.source)
        if status != noErr {
            NSLog("[InputSource] Failed to switch to \(layout.name): status=\(status)")
            return false
        }
        return true
    }

    func characterForKeycode(_ keycode: UInt16, layout: KeyboardLayout) -> String? {
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

            UCKeyTranslate(kbLayout, keycode, UInt16(kUCKeyActionDown), 0,
                           UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeyState, chars.count, &actualLength, &chars)

            guard actualLength > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualLength)
        }
    }

    func convertKeycodes(_ keycodes: [UInt16], toLayout layout: KeyboardLayout) -> String {
        var result = ""
        for kc in keycodes {
            if let ch = characterForKeycode(kc, layout: layout) {
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
            let lang = detectLanguage(id: id)

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

    private func detectLanguage(id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("russian") { return "ru" }
        if lowered.contains("ukrainian") { return "uk" }
        if lowered.contains("german") { return "de" }
        if lowered.contains("french") { return "fr" }
        return "en"
    }

    @objc private func inputSourceChanged() {
        reloadLayouts()
        let layoutName = currentLayout?.name ?? "?"
        let lang = currentLayout?.languageCode ?? "?"
        DebugLog.shared.log("IS", "layout changed → \(lang):\(layoutName)")
        NotificationCenter.default.post(name: .layoutChanged, object: nil)
    }
}
