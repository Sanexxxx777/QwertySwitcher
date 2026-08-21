import Foundation
import AppKit

struct AppProfile: Codable, Equatable {
    var blockAutoSwitch: Bool
    var blockInstantCorrection: Bool
    var blockHotkeys: Bool

    init(
        blockAutoSwitch: Bool = true,
        blockInstantCorrection: Bool = false,
        blockHotkeys: Bool = false
    ) {
        self.blockAutoSwitch = blockAutoSwitch
        self.blockInstantCorrection = blockInstantCorrection
        self.blockHotkeys = blockHotkeys
    }

    var isEmpty: Bool {
        !blockAutoSwitch && !blockInstantCorrection && !blockHotkeys
    }
}

final class ExceptionsService {
    private let defaults: UserDefaults
    private let wordExceptionsKey = AppIdentity.keyPrefix + "wordExceptions"
    private let appExceptionsKey = AppIdentity.keyPrefix + "appExceptions"
    private let appProfilesKey = AppIdentity.keyPrefix + "appProfiles.v1"
    private let autoLearnedKey = AppIdentity.keyPrefix + "autoLearned"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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

    var appProfiles: [String: AppProfile] {
        get {
            if let data = defaults.data(forKey: appProfilesKey),
               let decoded = try? JSONDecoder().decode([String: AppProfile].self, from: data) {
                return decoded
            }
            let legacy = defaults.stringArray(forKey: appExceptionsKey) ?? defaultAppExceptions
            return Dictionary(uniqueKeysWithValues: legacy.map { ($0, AppProfile()) })
        }
        set {
            let normalized = newValue.filter { !$0.key.isEmpty && !$0.value.isEmpty }
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: appProfilesKey)
            defaults.removeObject(forKey: appExceptionsKey)
        }
    }

    /// Compatibility surface for the old all-or-nothing app exception list.
    /// Existing installs migrate lazily into profiles on the first mutation.
    var appExceptions: Set<String> {
        get { Set(appProfiles.compactMap { $0.value.blockAutoSwitch ? $0.key : nil }) }
        set {
            var profiles = appProfiles
            for bundleID in Array(profiles.keys) {
                profiles[bundleID]?.blockAutoSwitch = newValue.contains(bundleID)
            }
            for bundleID in newValue where profiles[bundleID] == nil {
                profiles[bundleID] = AppProfile()
            }
            appProfiles = profiles
        }
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
        var profiles = appProfiles
        var profile = profiles[bundleID] ?? AppProfile()
        profile.blockAutoSwitch = true
        profiles[bundleID] = profile
        appProfiles = profiles
    }

    func removeAppException(_ bundleID: String) {
        var profiles = appProfiles
        guard var profile = profiles[bundleID] else { return }
        profile.blockAutoSwitch = false
        profiles[bundleID] = profile.isEmpty ? nil : profile
        appProfiles = profiles
    }

    func setProfile(_ profile: AppProfile, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var profiles = appProfiles
        profiles[bundleID] = profile.isEmpty ? nil : profile
        appProfiles = profiles
    }

    func removeProfiles(for bundleIDs: Set<String>) {
        var profiles = appProfiles
        for bundleID in bundleIDs { profiles.removeValue(forKey: bundleID) }
        appProfiles = profiles
    }

    func profile(for bundleID: String) -> AppProfile? {
        appProfiles[bundleID]
    }

    func blocksAutoSwitch(bundleID: String) -> Bool {
        appProfiles[bundleID]?.blockAutoSwitch ?? false
    }

    func blocksInstantCorrection(bundleID: String) -> Bool {
        appProfiles[bundleID]?.blockInstantCorrection ?? false
    }

    func blocksHotkeys(bundleID: String) -> Bool {
        appProfiles[bundleID]?.blockHotkeys ?? false
    }

    func areHotkeysBlockedForCurrentApp() -> Bool {
        guard let bundleID = currentAppBundleID() else { return false }
        return blocksHotkeys(bundleID: bundleID)
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
