import Foundation
import Combine
import CryptoKit
import Security

// MARK: - Payload & canonicalization

/// Signed license payload as returned by the server inside `{"payload": …}`.
struct LicensePayload: Codable, Equatable {
    let hwid: String
    let plan: String
    let start: Int64
    let until: Int64
    let issued: Int64

    /// Canonical string, byte-for-byte matching Python's
    /// `json.dumps(payload, sort_keys=True, separators=(",", ":"))` for this
    /// exact field set. Built by hand (not `JSONEncoder`) because key order
    /// and number formatting must match the server signer precisely.
    var canonicalString: String {
        "{\"hwid\":\"\(Self.escaped(hwid))\"," +
            "\"issued\":\(issued)," +
            "\"plan\":\"\(Self.escaped(plan))\"," +
            "\"start\":\(start)," +
            "\"until\":\(until)}"
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Locally persisted license state (Keychain in production, in-memory in tests).
struct LicenseState: Codable, Equatable {
    var payload: LicensePayload?
    var sig: String?
    var lastCheckUnix: Int64
    var maxSeenUnix: Int64
    var provisional: Bool

    /// A 14-day trial created entirely locally when there is no cached state
    /// and the server cannot be reached (e.g. first launch, offline). Has no
    /// signature — it is replaced by the server's authoritative answer as
    /// soon as one successful check-in happens (the server may already know
    /// an earlier trial for this hwid).
    static func provisionalTrial(hwid: String, now: Int64) -> LicenseState {
        let trialSeconds: Int64 = 14 * 24 * 3600
        let payload = LicensePayload(hwid: hwid, plan: "trial", start: now, until: now + trialSeconds, issued: now)
        return LicenseState(payload: payload, sig: nil, lastCheckUnix: now, maxSeenUnix: now, provisional: true)
    }
}

// MARK: - Signature verification

enum LicenseVerifier {
    /// `payload.hwid`/`issued` sanity + Ed25519 signature check over the
    /// canonical payload string. `publicKeyHex` defaults to the embedded
    /// production key and is overridable only for tests.
    static func verifySignature(
        payload: LicensePayload, sigHex: String,
        publicKeyHex: String = LicenseService.embeddedPublicKeyHex
    ) -> Bool {
        guard let keyData = Data(hexString: publicKeyHex),
              let sigData = Data(hexString: sigHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return publicKey.isValidSignature(sigData, for: Data(payload.canonicalString.utf8))
    }

    /// Full acceptance check for a payload freshly received from the server:
    /// signature + hwid binding + issue-time sanity (±48h) against replay or
    /// gross clock skew. Used only when accepting a NEW server response —
    /// routine re-evaluation of already-cached state does not re-check
    /// `issued`, since a long-lived subscription's `issued` timestamp is
    /// expected to age well past 48h.
    static func accept(
        payload: LicensePayload, sigHex: String, hwid: String, now: Int64,
        publicKeyHex: String = LicenseService.embeddedPublicKeyHex
    ) -> Bool {
        guard verifySignature(payload: payload, sigHex: sigHex, publicKeyHex: publicKeyHex) else { return false }
        guard payload.hwid == hwid else { return false }
        guard abs(payload.issued - now) < 172_800 else { return false }
        return true
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 2
        }
        self = Data(bytes)
    }
}

// MARK: - Test seams

protocol LicenseClock {
    func now() -> Int64
}

struct SystemClock: LicenseClock {
    func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

protocol LicenseStateStore {
    func load() -> LicenseState?
    func save(_ state: LicenseState)
}

/// Reads/deletes the pre-0.4.4 Keychain-stored license state exactly once,
/// during migration into `FileLicenseStore`. `kSecUseAuthenticationUISkip` is
/// mandatory on both calls: self-signed builds get a new CDHash on every
/// rebuild, so macOS treats the ACL as belonging to a new app and would
/// otherwise show a password prompt on every single read — skipping just
/// means "fail silently instead of prompting", exactly what a best-effort
/// one-shot migration needs.
protocol LegacyLicenseKeychainReader {
    func readSilently() -> LicenseState?
    func deleteSilently()
}

final class SystemLegacyLicenseKeychainReader: LegacyLicenseKeychainReader {
    private let service = AppIdentity.bundleIdentifier + ".license"
    private let account = "state"

    func readSilently() -> LicenseState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(LicenseState.self, from: data)
    }

    func deleteSilently() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Production license store since 0.4.4 — replaces Keychain entirely (see
/// CLAUDE.md "Убрать диалоги Keychain"). The payload is Ed25519-signed by the
/// server (can't be forged locally, only deleted) and carries no secrets, so
/// a plain 0600 file loses nothing over Keychain while sidestepping the
/// CDHash-ACL prompt for self-signed builds. Migrates the old Keychain entry
/// once, on first launch after upgrade, then never touches Security.framework
/// again — this is the last SecItem* call anywhere in the license path.
final class FileLicenseStore: LicenseStateStore {
    private let fm: FileManager
    private let url: URL
    private let legacyReader: LegacyLicenseKeychainReader

    init(
        directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.compactName, isDirectory: true),
        legacyReader: LegacyLicenseKeychainReader = SystemLegacyLicenseKeychainReader(),
        fileManager: FileManager = .default
    ) {
        self.fm = fileManager
        self.legacyReader = legacyReader
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("license.json")
        migrateFromKeychainIfNeeded()
    }

    func load() -> LicenseState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LicenseState.self, from: data)
    }

    func save(_ state: LicenseState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            DebugLog.shared.log("LIC", "failed to persist license state to disk")
        }
    }

    /// Guarded so an already-migrated install never touches Keychain again.
    private func migrateFromKeychainIfNeeded() {
        guard !fm.fileExists(atPath: url.path) else { return }
        guard let legacy = legacyReader.readSilently() else { return }
        save(legacy)
        legacyReader.deleteSilently()
    }
}

protocol LicenseTransport {
    func hello(
        baseURL: URL, hwid: String, appVersion: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    )
    func activate(
        baseURL: URL, hwid: String, key: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    )
}

private struct ServerEnvelope: Decodable {
    let payload: LicensePayload
    let sig: String
}

private struct ServerErrorEnvelope: Decodable {
    let error: String
}

/// Production transport. Completion is always delivered on the main queue so
/// `LicenseService`'s `@Published` state is only ever mutated from main —
/// test doubles instead call completion synchronously on the caller's thread
/// (the standalone test runner has no run loop to hop through).
final class URLSessionLicenseTransport: LicenseTransport {
    private let session: URLSession = .shared

    func hello(
        baseURL: URL, hwid: String, appVersion: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        post(
            url: baseURL.appendingPathComponent("v1/hello"),
            body: ["hwid": hwid, "app_version": appVersion],
            completion: completion
        )
    }

    func activate(
        baseURL: URL, hwid: String, key: String,
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        post(
            url: baseURL.appendingPathComponent("v1/activate"),
            body: ["hwid": hwid, "key": key],
            completion: completion
        )
    }

    private func post(
        url: URL, body: [String: String],
        completion: @escaping (LicenseService.ServerResult) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        session.dataTask(with: request) { data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parse(
        data: Data?, response: URLResponse?, error: Error?
    ) -> LicenseService.ServerResult {
        guard error == nil, let http = response as? HTTPURLResponse, let data else {
            return .failure(.network)
        }
        if http.statusCode == 200,
           let envelope = try? JSONDecoder().decode(ServerEnvelope.self, from: data) {
            return .success(payload: envelope.payload, sigHex: envelope.sig)
        }
        if http.statusCode == 400,
           let err = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
            switch err.error {
            case "invalid_key": return .failure(.invalidKey)
            case "key_used": return .failure(.keyUsed)
            default: return .failure(.network)
            }
        }
        return .failure(.network)
    }
}

// MARK: - LicenseService

final class LicenseService: ObservableObject {
    static let shared = LicenseService()

    static let embeddedPublicKeyHex =
        "e1253172d80dea23c56d28b4c9fb35e30c9c5e3bde8eab543965e43bc6c0035d"

    private static let graceSeconds: Int64 = 14 * 24 * 3600
    private static let rollbackToleranceSeconds: Int64 = 3600
    private static let checkInInterval: TimeInterval = 12 * 3600
    /// Anti-tamper for the offline-only path: UserDefaults, separate from
    /// `store`, marks the first time this hwid was ever seen — so deleting
    /// the license file/state alone (with no network) can't restart the
    /// provisional trial. The server stays authoritative; this only bounds
    /// what an offline-only attacker can get by wiping local state.
    private static let firstSeenKeyPrefix = AppIdentity.keyPrefix + "licenseFirstSeen."

    enum ServerError: Equatable {
        case invalidKey
        case keyUsed
        case network
    }

    enum ServerResult {
        case success(payload: LicensePayload, sigHex: String)
        case failure(ServerError)
    }

    enum ActivationOutcome: Equatable {
        case success
        case invalidKey
        case keyUsed
        case network
        case serverError
    }

    @Published private(set) var isEntitled: Bool = false {
        didSet {
            guard isEntitled != oldValue else { return }
            DebugLog.shared.log("LIC", "entitlement \(oldValue) → \(isEntitled)")
            NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        }
    }

    private let clock: LicenseClock
    private let transport: LicenseTransport
    private let store: LicenseStateStore
    private let hwid: String
    private let appVersion: String
    private let publicKeyHex: String
    private var state: LicenseState?
    private var checkInTimer: Timer?

    var baseURL: URL {
        let defaultURLString = "https://backend-test.45-82-95-142.nip.io:8443/qsw"
        let key = AppIdentity.keyPrefix + "licenseServerURL"
        let stored = UserDefaults.standard.string(forKey: key)
        return URL(string: stored ?? defaultURLString) ?? URL(string: defaultURLString)!
    }

    init(
        clock: LicenseClock = SystemClock(),
        transport: LicenseTransport = URLSessionLicenseTransport(),
        store: LicenseStateStore = FileLicenseStore(),
        hwid: String = DeviceIdentity.hardwareUUID(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        publicKeyHex: String = LicenseService.embeddedPublicKeyHex
    ) {
        self.clock = clock
        self.transport = transport
        self.store = store
        self.hwid = hwid
        self.appVersion = appVersion
        self.publicKeyHex = publicKeyHex
        self.state = store.load()
        recordFirstSeenIfNeeded(now: clock.now())
        recomputeEntitlement()
    }

    // MARK: - Public read surface (for UI)

    var currentPayload: LicensePayload? { state?.payload }
    var isProvisionalTrial: Bool { state?.provisional ?? false }

    var daysRemaining: Int {
        guard let until = state?.payload?.until else { return 0 }
        let remaining = until - clock.now()
        return max(0, Int((remaining + 86_399) / 86_400))
    }

    var statusHeadline: String {
        guard let payload = state?.payload else { return "Лицензия не активирована" }
        if !isEntitled { return "Срок истёк" }
        let untilText = Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(payload.until)))
        if payload.plan == "trial" || isProvisionalTrial {
            return "Пробный период до \(untilText)"
        }
        return "Подписка активна до \(untilText)"
    }

    var statusSummary: String {
        guard state?.payload != nil else { return "Лицензия" }
        return isEntitled ? "Лицензия · \(daysRemaining) дн." : "Лицензия · истекла"
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d MMMM yyyy"
        df.locale = Locale(identifier: "ru_RU")
        return df
    }()

    // MARK: - Lifecycle

    /// Starts periodic check-ins (immediate + every 12h). Call once at app launch.
    func start() {
        checkIn()
        checkInTimer?.invalidate()
        let timer = Timer(timeInterval: Self.checkInInterval, repeats: true) { [weak self] _ in
            self?.checkIn()
        }
        RunLoop.main.add(timer, forMode: .common)
        checkInTimer = timer
    }

    func checkIn() {
        transport.hello(baseURL: baseURL, hwid: hwid, appVersion: appVersion) { [weak self] result in
            self?.handleServerResult(result)
        }
    }

    func activate(key: String, completion: @escaping (ActivationOutcome) -> Void) {
        DebugLog.shared.log("LIC", "activate requested key=\(Self.redacted(key))")
        transport.activate(baseURL: baseURL, hwid: hwid, key: key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload, let sig):
                if self.applyServerResponse(payload: payload, sigHex: sig) {
                    DebugLog.shared.log("LIC", "activation accepted plan=\(payload.plan)")
                    completion(.success)
                } else {
                    DebugLog.shared.log("LIC", "activation response failed verification")
                    completion(.serverError)
                }
            case .failure(.invalidKey):
                completion(.invalidKey)
            case .failure(.keyUsed):
                completion(.keyUsed)
            case .failure(.network):
                completion(.network)
            }
        }
    }

    private static func redacted(_ key: String) -> String {
        String(key.prefix(6)) + "…"
    }

    // MARK: - State transitions

    private func handleServerResult(_ result: ServerResult) {
        switch result {
        case .success(let payload, let sig):
            if applyServerResponse(payload: payload, sigHex: sig) {
                // Positive evidence a check-in actually succeeded — the
                // failure path already logs every unreachable attempt, but a
                // healthy check-in was previously invisible in the log.
                DebugLog.shared.log("LIC", "check-in ok plan=\(payload.plan) daysLeft=\(daysRemaining)")
            } else {
                DebugLog.shared.log("LIC", "check-in response failed verification")
            }
        case .failure(let error):
            DebugLog.shared.log("LIC", "check-in unreachable: \(error)")
            applyOfflineResult()
        }
    }

    /// Accepts a verified server response as the new authoritative state.
    @discardableResult
    func applyServerResponse(payload: LicensePayload, sigHex: String) -> Bool {
        let now = clock.now()
        guard LicenseVerifier.accept(payload: payload, sigHex: sigHex, hwid: hwid, now: now, publicKeyHex: publicKeyHex)
        else { return false }
        let newState = LicenseState(
            payload: payload, sig: sigHex,
            lastCheckUnix: now, maxSeenUnix: max(state?.maxSeenUnix ?? 0, now),
            provisional: false
        )
        state = newState
        store.save(newState)
        recomputeEntitlement()
        return true
    }

    /// Server unreachable: applies grace/rollback rules to cached state, and
    /// provisions a local 14-day trial anchored at `firstSeenTimestamp` — a
    /// genuinely first-ever launch anchors at `now`; a launch that lost its
    /// local state (file deleted) anchors at the original first-seen time
    /// instead, so it can't get a second free trial while offline.
    func applyOfflineResult() {
        let now = clock.now()
        if state == nil {
            let anchor = firstSeenTimestamp(defaultingTo: now)
            let trial = LicenseState.provisionalTrial(hwid: hwid, now: anchor)
            state = trial
            store.save(trial)
            if anchor == now {
                DebugLog.shared.log("LIC", "offline first launch — provisional trial started")
            } else {
                DebugLog.shared.log("LIC", "offline + no local state — trial restored from first-seen anchor, not restarted")
            }
        } else if let cached = state, cached.sig != nil, !cached.provisional {
            // Positive evidence for the offline-grace window itself — the
            // server being unreachable is already logged above; this makes
            // "still inside grace" vs "grace ran out" visible without having
            // to reason about it from lastCheckUnix by hand.
            let graceLeftDays = (Self.graceSeconds - (now - cached.lastCheckUnix)) / 86_400
            if graceLeftDays >= 0 {
                DebugLog.shared.log("LIC", "offline grace: \(graceLeftDays)d left before entitlement lapses")
            } else {
                DebugLog.shared.log("LIC", "offline grace expired \(-graceLeftDays)d ago")
            }
        }
        recomputeEntitlement()
    }

    private func recordFirstSeenIfNeeded(now: Int64) {
        let key = Self.firstSeenKeyPrefix + hwid
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(Int(now), forKey: key)
    }

    private func firstSeenTimestamp(defaultingTo now: Int64) -> Int64 {
        let key = Self.firstSeenKeyPrefix + hwid
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int else { return now }
        return Int64(stored)
    }

    private func recomputeEntitlement() {
        isEntitled = Self.evaluate(
            state: state, hwid: hwid, now: clock.now(),
            graceSeconds: Self.graceSeconds, rollbackTolerance: Self.rollbackToleranceSeconds,
            publicKeyHex: publicKeyHex
        )
    }

    /// Pure entitlement rule, independent of network/storage — directly testable.
    static func evaluate(
        state: LicenseState?, hwid: String, now: Int64,
        graceSeconds: Int64, rollbackTolerance: Int64,
        publicKeyHex: String = LicenseService.embeddedPublicKeyHex
    ) -> Bool {
        guard let state, let payload = state.payload else { return false }
        guard payload.hwid == hwid else { return false }

        // Clock rollback: cache cannot be trusted once "now" moves backward
        // past what we've already observed — only a fresh server check can
        // restore trust.
        if now < state.maxSeenUnix - rollbackTolerance { return false }

        guard payload.until > now else { return false }

        if state.provisional { return true }

        guard let sig = state.sig,
              LicenseVerifier.verifySignature(payload: payload, sigHex: sig, publicKeyHex: publicKeyHex)
        else { return false }

        let staleness = now - state.lastCheckUnix
        return staleness < graceSeconds
    }
}

extension Notification.Name {
    static let licenseStatusChanged = Notification.Name(AppIdentity.keyPrefix + "licenseStatusChanged")
}
