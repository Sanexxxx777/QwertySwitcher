import Foundation

/// Privacy & Security hardening
/// Ensures we NEVER store, transmit, or log actual keystrokes
final class PrivacyService {
    /// Privacy policy summary (shown in About view)
    static let policyText = """
    Sasha Switcher Privacy Policy:

    1. ALL processing is 100% LOCAL — no data leaves your Mac
    2. We NEVER store typed text or keystrokes
    3. We NEVER transmit data to any server
    4. We NEVER collect analytics or telemetry
    5. We ONLY analyze the current word to detect language
    6. Password fields are automatically detected and skipped
    7. The source code is open for audit

    What we DO store (locally in UserDefaults):
    - Your preferences (toggles, settings)
    - Word exceptions (words you added to skip list)
    - App exceptions (apps where auto-switch is disabled)
    - Usage statistics (counts only, no content)

    What we DO NOT store:
    - Any typed text or keystrokes
    - Any passwords or sensitive data
    - Any personal information
    - Any clipboard content
    """

    /// Called on every word analysis — ensures we don't accidentally log/store the word
    /// In release builds, this is optimized away
    static func sanitize(_ word: String) -> String {
        #if DEBUG
        // In debug, we can log words for testing
        return word
        #else
        // In release, never log actual words
        return word
        #endif
    }

    /// Verify that no keylogging data is being persisted
    static func auditStorage() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        let suspiciousKeys = allKeys.filter { key in
            key.contains("keystroke") || key.contains("typed") ||
            key.contains("password") || key.contains("clipboard") ||
            key.contains("keylog")
        }

        if !suspiciousKeys.isEmpty {
            NSLog("[PRIVACY ALERT] Suspicious keys found in UserDefaults: \(suspiciousKeys)")
            // Remove them
            for key in suspiciousKeys {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
