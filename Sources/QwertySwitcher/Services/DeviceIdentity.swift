import Foundation
import IOKit
import Security

/// Generic Keychain read/write helper shared by `DeviceIdentity`'s fallback
/// UUID and `LicenseService`'s persisted state.
enum KeychainStore {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

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
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ] as CFDictionary)
        if updateStatus == errSecItemNotFound {
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
