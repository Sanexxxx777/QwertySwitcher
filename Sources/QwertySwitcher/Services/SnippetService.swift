import Foundation

final class SnippetService {
    private let defaults: UserDefaults
    private let key = AppIdentity.keyPrefix + "snippets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var snippets: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    func isValidTrigger(_ value: String) -> Bool {
        let trigger = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trigger.count >= 2, trigger.count <= 32 else { return false }
        return trigger.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    func isValidReplacement(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_000 && !value.contains("\0")
    }

    @discardableResult
    func setSnippet(trigger: String, replacement: String) -> Bool {
        let normalized = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidTrigger(normalized), isValidReplacement(replacement) else { return false }
        var current = snippets
        current[normalized] = replacement
        snippets = current
        return true
    }

    func removeSnippet(trigger: String) {
        var current = snippets
        current.removeValue(forKey: trigger.lowercased())
        snippets = current
    }

    func replacement(for trigger: String) -> String? {
        snippets[trigger.lowercased()]
    }
}
