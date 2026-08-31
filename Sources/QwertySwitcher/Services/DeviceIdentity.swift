import Foundation
import IOKit
import Security

/// Generic Keychain read/write helper shared by `DeviceIdentity`'s fallback
/// UUID and `LicenseService`'s persisted state.
enum KeychainStore {
    /// Reads never show the "wants to use confidential information" dialog.
    /// A self-signed dev build has an unstable CDHash (see CLAUDE.md
    /// "Обновление установленной копии"), so an item written by a previous
    /// build's process routinely looks like "someone else's ACL" to the
    /// current one — `kSecUseAuthenticationUISkip` is documented (SecItem.h)
    /// to silently skip such items instead of prompting; the caller already
    /// treats a missing/inaccessible value as absent (DeviceIdentity's
    /// persisted-fallback-UUID regenerates, LicenseService's first-seen
    /// anchor falls back to its other candidates).
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Silent existence probe — reuses the same `kSecUseAuthenticationUISkip`
    /// path as `read` (that flag is documented to apply only to
    /// `SecItemCopyMatching`, not to `SecItemUpdate`/`SecItemAdd`), so `write`
    /// can decide whether touching the item is safe *before* calling either.
    private static func silentStatus(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    /// This is the exact class of failure that used to pop the auth dialog
    /// for a stale item owned by a previous build: the item exists but its
    /// ACL can't be satisfied without UI.
    private static func isAuthBlocked(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    /// Writes never show UI either. `kSecUseAuthenticationUISkip` can't be
    /// passed directly to `SecItemUpdate`/`SecItemAdd` (Apple's SecItem.h:
    /// "This value can be used only with SecItemCopyMatching") — so instead
    /// of guessing at their undocumented behavior, `write` probes silently
    /// first: item already readable by us → update it (same ACL, no auth
    /// expected); genuinely absent → add fresh (a brand-new item has no ACL
    /// to authenticate against yet); present but auth-blocked → give up
    /// without touching it, no retry. Callers that hit `false` already keep
    /// a non-Keychain source of truth (file anchor / freshly generated UUID).
    @discardableResult
    static func write(
        _ data: Data, service: String, account: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let probe = silentStatus(service: service, account: account)
        if isAuthBlocked(probe) { return false }

        if probe == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ] as CFDictionary)
        if isAuthBlocked(updateStatus) { return false }
        if updateStatus == errSecItemNotFound {
            // Raced with a delete between the probe above and here.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }
}

/// Stable per-Mac identifier used by the license layer and sent to the
/// Qwerty Switcher license server as `hwid`.
enum DeviceIdentity {
    private static let fallbackService = AppIdentity.bundleIdentifier + ".deviceid"
    private static let fallbackAccount = "fallback-uuid"

    /// Hardware UUID via IOKit `IOPlatformExpertDevice`, uppercased.
    /// Falls back to a UUID persisted in Keychain — should not happen on a
    /// real Mac, but keeps the license layer functional on unusual setups.
    static func hardwareUUID() -> String {
        if let uuid = ioPlatformUUID(), !uuid.isEmpty {
            return uuid.uppercased()
        }
        DebugLog.shared.log("LIC", "hwid: IOKit lookup failed, using persisted fallback")
        return persistedFallbackUUID()
    }

    private static func ioPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return cfValue.takeRetainedValue() as? String
    }

    private static func persistedFallbackUUID() -> String {
        if let data = KeychainStore.read(service: fallbackService, account: fallbackAccount),
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.uppercased()
        if let data = generated.data(using: .utf8) {
            KeychainStore.write(data, service: fallbackService, account: fallbackAccount)
        }
        return generated
    }
}
