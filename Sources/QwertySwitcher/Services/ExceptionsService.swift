import Foundation
import AppKit

final class ExceptionsService {
    private let defaults = UserDefaults.standard
    private let wordExceptionsKey = AppIdentity.keyPrefix + "wordExceptions"
    private let appExceptionsKey = AppIdentity.keyPrefix + "appExceptions"
    private let autoLearnedKey = AppIdentity.keyPrefix + "autoLearned"

    // MARK: - Word Exceptions (user-added words to never switch)

    var wordExceptions: Set<String> {
        get { Set(defaults.stringArray(forKey: wordExceptionsKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: wordExceptionsKey) }
    }

    /// Validate word exception (like Caramba's regex validator)
    func isValidException(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, w.count <= 20 else { return false }
        guard !w.contains("="), !w.contains("%"), !w.contains("/"), !w.contains("\\") else { return false }
        // Must contain at least one letter
        return w.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    func addWordException(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidException(cleaned) else { return }
        var current = wordExceptions
        current.insert(cleaned)
        wordExceptions = current
    }

    func removeWordException(_ word: String) {
        var current = wordExceptions
        current.remove(word.lowercased())
        wordExceptions = current
    }

    func isWordExcepted(_ word: String) -> Bool {
        wordExceptions.contains(word.lowercased())
    }

    // MARK: - App Exceptions (bundle IDs to skip auto-switch)

    var appExceptions: Set<String> {
        get { Set(defaults.stringArray(forKey: appExceptionsKey) ?? defaultAppExceptions) }
        set { defaults.set(Array(newValue).sorted(), forKey: appExceptionsKey) }
    }

    private let defaultAppExceptions = [
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.googlecode.iterm2",
        "io.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
    ]

    func addAppException(_ bundleID: String) {
        var current = appExceptions
        current.insert(bundleID)
        appExceptions = current
    }

    func removeAppException(_ bundleID: String) {
        var current = appExceptions
        current.remove(bundleID)
        appExceptions = current
    }

    func isCurrentAppExcepted() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return false }
        return appExceptions.contains(bundleID)
    }

    func currentAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func currentAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Auto-Learned Exceptions (from user corrections via backspace)

    var autoLearned: [String: String] {
        get { defaults.dictionary(forKey: autoLearnedKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: autoLearnedKey) }
    }

    /// Record that user cancelled auto-switch by pressing backspace after correction
    func learnException(original: String, corrected: String) {
        var learned = autoLearned
        learned[original.lowercased()] = corrected.lowercased()
        autoLearned = learned
        DebugLog.shared.log(
            "AUTOLEARN",
            "exception stored originalLen=\(original.count) replacementLen=\(corrected.count)"
        )
    }

    func isAutoLearned(_ word: String) -> Bool {
        autoLearned[word.lowercased()] != nil
    }

    func removeAutoLearned(_ word: String) {
        var learned = autoLearned
        learned.removeValue(forKey: word.lowercased())
        autoLearned = learned
    }
}
