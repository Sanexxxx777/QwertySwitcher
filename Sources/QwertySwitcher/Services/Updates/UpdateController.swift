import Foundation
import AppKit

/// Owns the whole opt-in updater lifecycle: scheduling, the feed check,
/// staging, and — when safe — installing. A single instance lives for the
/// app's lifetime (created in `AppDelegate`); both `MainViewModel` and
/// `StatusBarController` read its `@Published status` for the UI.
final class UpdateController: ObservableObject {
    enum Status: Equatable {
        case idle(lastCheckAt: Date?)
        case checking
        case upToDate(checkedAt: Date)
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        case readyToInstall(UpdateManifest, deferred: Bool)
        /// A MANUAL "Установить" click hit a transient safety gate
        /// (secure input / mid-replacement) — retrying every few seconds
        /// until it's safe, capped at 5 minutes.
        case installPendingSafeWindow(UpdateManifest)
        case installing
        case feedStale(validUntil: Date, checkedAt: Date)
        case systemTooOld(manifest: UpdateManifest, checkedAt: Date)
        case feedInvalid
        case identityMismatch
        case cannotInstallHere
        case networkError
    }

    @Published private(set) var status: Status

    private let prefsService: PreferencesService
    private let installedBundle: URL
    private let userAgent: String
    private let safetySnapshotProvider: () -> (idleSeconds: TimeInterval, gameModeActive: Bool, replacing: Bool)
    private let secureInputProvider: () -> Bool
    private let screenLockedProvider: () -> Bool
    private var checkTimer: Timer?
    private var windowRetryTimer: Timer?
    private var manualRetryTimer: Timer?
    private var pendingStagedUpdate: UpdateStager.StagedUpdate?

    init(
        prefsService: PreferencesService,
        installedBundle: URL = Bundle.main.bundleURL,
        safetySnapshotProvider: @escaping () -> (idleSeconds: TimeInterval, gameModeActive: Bool, replacing: Bool),
        secureInputProvider: @escaping () -> Bool,
        screenLockedProvider: @escaping () -> Bool = { false }
    ) {
        self.prefsService = prefsService
        self.installedBundle = installedBundle
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        self.userAgent = "QwertySwitcher/\(version)"
        self.safetySnapshotProvider = safetySnapshotProvider
        self.secureInputProvider = secureInputProvider
        self.screenLockedProvider = screenLockedProvider
        self.status = .idle(lastCheckAt: prefsService.updatesLastCheckAt)
    }

    /// Maps the (richer) UI status down to the coarse activity buckets
    /// `UpdatePolicy.canStartNewCheck` reasons about — kept as a pure,
    /// separately-testable function rather than inlining the switch.
    private var activityState: UpdatePolicy.ActivityState {
        switch status {
        case .checking: return .checking
        case .downloading: return .downloading
        case .installing, .installPendingSafeWindow: return .installing
        default: return .idle
        }
    }

    // MARK: - Scheduling

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdatePolicy.firstCheckDelay) { [weak self] in
            self?.tickScheduled()
        }
        let timer = Timer(timeInterval: UpdatePolicy.checkInterval, repeats: true) { [weak self] _ in
            self?.tickScheduled()
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func tickScheduled() {
        guard UpdatePolicy.shouldCheck(
            now: Date(), lastCheckAt: prefsService.updatesLastCheckAt,
            lastFailureAt: prefsService.updatesLastFailureAt, autoCheck: prefsService.updatesAutoCheck
        ) else { return }
        checkNow(userInitiated: false)
    }

    // MARK: - Entry points

    /// `userInitiated` bypasses the 24h cadence gate (spec: manual "Проверить
    /// сейчас" works even with the toggle off) — it does NOT bypass the
    /// install-safety gates, only the schedule. MAJOR fix (security review):
    /// this used to unconditionally set `.checking` even while a check or an
    /// install was already in flight — the 24h timer and a manual click
    /// could both start a `stage()` at once, and `.checking` would stomp a
    /// live `.downloading`/`.installing` status. Now gated by
    /// `UpdatePolicy.canStartNewCheck`; a manual click during one is a
    /// logged no-op instead of a second race.
    func checkNow(userInitiated: Bool = true) {
        guard UpdatePolicy.canStartNewCheck(current: activityState) else {
            DebugLog.shared.log("UPD", "check already in progress — ignoring \(userInitiated ? "manual" : "scheduled") request")
            return
        }
        status = .checking
        let client = UpdateFeedClient(feedURLProvider: { [prefsService] in prefsService.updatesFeedURL }, userAgent: userAgent)
        client.fetchManifest { [weak self] result in
            DispatchQueue.main.async { self?.handleFeedResult(result) }
        }
    }

    /// Manual "Установить" — explicit user action. Works from BOTH `.available`
    /// (stage first, then install) and `.readyToInstall` (already staged by
    /// the automatic path but not installed yet, e.g. auto-install is off).
    func installAvailableUpdate() {
        switch status {
        case .available(let manifest):
            maybeStageAndInstall(manifest: manifest, userInitiated: true)
        case .readyToInstall:
            guard let staged = pendingStagedUpdate else { return }
            attemptManualInstall(staged: staged)
        default:
            break
        }
    }

    // MARK: - Feed handling

    private func handleFeedResult(_ result: Result<UpdateManifest, UpdateFeedClient.FeedError>) {
        let now = Date()
        switch result {
        case .failure(let error):
            prefsService.updatesLastFailureAt = now
            DebugLog.shared.log("UPD", "check failed: \(error)")
            if case .verification = error {
                status = .feedInvalid
            } else {
                status = .networkError
            }
        case .success(let manifest):
            prefsService.updatesLastCheckAt = now
            // MINOR fix (security review): a successful check used to leave
            // a stale `updatesLastFailureAt` behind — `UpdatePolicy.shouldCheck`
            // would then honor a 6h backoff against a failure that has long
            // since been superseded by a working check.
            prefsService.updatesLastFailureAt = nil
            let installedBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
            let outcome = UpdatePolicy.evaluate(
                manifest: manifest, installedBuild: installedBuild,
                lastSeenBuild: prefsService.updatesLastSeenBuild,
                currentSystemVersion: ProcessInfo.processInfo.operatingSystemVersion, now: now
            )
            DebugLog.shared.log("UPD", "check ok: build=\(manifest.build) outcome=\(outcome)")
            switch outcome {
            case .upToDate:
                status = .upToDate(checkedAt: now)
            case .systemTooOld(let manifest):
                status = .systemTooOld(manifest: manifest, checkedAt: now)
            case .feedStale(let manifest):
                let validUntil = UpdatePolicy.parseISO8601(manifest.validUntil) ?? now
                status = .feedStale(validUntil: validUntil, checkedAt: now)
            case .available(let manifest):
                status = .available(manifest)
                maybeStageAndInstall(manifest: manifest, userInitiated: false)
            }
        }
    }

    // MARK: - Staging + install timing

    private func maybeStageAndInstall(manifest: UpdateManifest, userInitiated: Bool) {
        guard UpdateTargetGuard.canAutoInstall(target: installedBundle) else {
            status = .cannotInstallHere
            DebugLog.shared.log("UPD", "target not writable or marked broken — notify-only")
            return
        }
        status = .downloading(manifest)
        let stager = UpdateStager(userAgent: userAgent)
        stager.stage(manifest: manifest, installedBundle: installedBundle) { [weak self] result in
            DispatchQueue.main.async { self?.handleStageResult(result, manifest: manifest, userInitiated: userInitiated) }
        }
    }

    private func handleStageResult(_ result: Result<UpdateStager.StagedUpdate, UpdateStager.StageError>,
                                    manifest: UpdateManifest, userInitiated: Bool) {
        switch result {
        case .failure(let error):
            DebugLog.shared.log("UPD", "stage failed: \(error)")
            if case .identityMismatch = error {
                status = .identityMismatch
            } else {
                status = .available(manifest) // transient stage failure — keep offering, try again later
            }
        case .success(let staged):
            pendingStagedUpdate = staged
            decideInstallTiming(staged: staged, userInitiated: userInitiated)
        }
    }

    private func decideInstallTiming(staged: UpdateStager.StagedUpdate, userInitiated: Bool) {
        if userInitiated {
            attemptManualInstall(staged: staged)
            return
        }
        guard prefsService.updatesAutoInstall else {
            status = .readyToInstall(staged.manifest, deferred: false)
            return
        }
        let snapshot = safetySnapshotProvider()
        let secure = secureInputProvider()
        let locked = screenLockedProvider()
        let allowed = UpdatePolicy.shouldInstallNow(
            autoInstall: prefsService.updatesAutoInstall,
            idleSeconds: snapshot.idleSeconds, secureInput: secure,
            replacing: snapshot.replacing, gameModeActive: snapshot.gameModeActive,
            screenLocked: locked
        )
        if allowed {
            performInstall(staged: staged)
        } else {
            logInstallDeferral(snapshot: snapshot, secure: secure, locked: locked)
            status = .readyToInstall(staged.manifest, deferred: false)
            scheduleInstallWindowRetry(staged: staged)
        }
    }

    /// Field e2e 10.09.2026: a deferred auto-install left NO trace in the log
    /// ("check ok" and then silence for 15 minutes) — undiagnosable from
    /// outside, exactly the class of silence the instant path once had.
    private func logInstallDeferral(
        snapshot: (idleSeconds: TimeInterval, gameModeActive: Bool, replacing: Bool), secure: Bool, locked: Bool
    ) {
        DebugLog.shared.log(
            "UPD",
            "install deferred: idle=\(Int(snapshot.idleSeconds))s secureInput=\(secure)"
                + " replacing=\(snapshot.replacing) game=\(snapshot.gameModeActive) screenLocked=\(locked)",
            level: .verbose
        )
    }

    /// MAJOR fix (security review): manual "Установить" used to go straight
    /// to `performInstall`, bypassing `replacing`/secure-input entirely —
    /// terminating the app mid-replacement is exactly the "text erased and
    /// never retyped" failure `TextReplacer`'s atomicity guard exists to
    /// avoid. Idle time and Game Mode are deliberately NOT required here —
    /// those only keep the SILENT automatic path unsurprising, not an
    /// explicit user click.
    private func attemptManualInstall(staged: UpdateStager.StagedUpdate) {
        let allowed = UpdatePolicy.shouldInstallManuallyNow(
            secureInput: secureInputProvider(), replacing: safetySnapshotProvider().replacing
        )
        if allowed {
            performInstall(staged: staged)
        } else {
            status = .installPendingSafeWindow(staged.manifest)
            scheduleManualInstallRetry(staged: staged)
        }
    }

    private func scheduleManualInstallRetry(staged: UpdateStager.StagedUpdate) {
        manualRetryTimer?.invalidate()
        let startedAt = Date()
        let deadline: TimeInterval = 5 * 60
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.pendingStagedUpdate != nil else { timer.invalidate(); return }
            let allowed = UpdatePolicy.shouldInstallManuallyNow(
                secureInput: self.secureInputProvider(), replacing: self.safetySnapshotProvider().replacing
            )
            if allowed {
                timer.invalidate()
                self.performInstall(staged: staged)
                return
            }
            if Date().timeIntervalSince(startedAt) >= deadline {
                timer.invalidate()
                self.status = .readyToInstall(staged.manifest, deferred: false)
                DebugLog.shared.log("UPD", "manual install could not find a safe window within 5 minutes")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualRetryTimer = timer
    }

    private func scheduleInstallWindowRetry(staged: UpdateStager.StagedUpdate) {
        windowRetryTimer?.invalidate()
        let startedAt = Date()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.prefsService.updatesAutoInstall, self.pendingStagedUpdate != nil else {
                timer.invalidate()
                return
            }
            if Date().timeIntervalSince(startedAt) >= UpdatePolicy.deferredInstallWindow {
                timer.invalidate()
                self.status = .readyToInstall(staged.manifest, deferred: true)
                DebugLog.shared.log("UPD", "install deferred to next launch after 6h with no safe window")
                return
            }
            let snapshot = self.safetySnapshotProvider()
            let secure = self.secureInputProvider()
            let locked = self.screenLockedProvider()
            let allowed = UpdatePolicy.shouldInstallNow(
                autoInstall: self.prefsService.updatesAutoInstall,
                idleSeconds: snapshot.idleSeconds, secureInput: secure,
                replacing: snapshot.replacing, gameModeActive: snapshot.gameModeActive,
                screenLocked: locked
            )
            if allowed {
                timer.invalidate()
                self.performInstall(staged: staged)
            } else {
                self.logInstallDeferral(snapshot: snapshot, secure: secure, locked: locked)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowRetryTimer = timer
    }

    private func performInstall(staged: UpdateStager.StagedUpdate) {
        status = .installing
        DebugLog.shared.log("UPD", "installing build \(staged.manifest.build)")
        UpdateInstallLauncher.launch(staged: staged, installedBundle: installedBundle) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    NSApp.terminate(nil)
                case .failure(let error):
                    DebugLog.shared.log("UPD", "install launch failed: \(error)")
                    self?.status = .available(staged.manifest)
                }
            }
        }
    }

    // MARK: - UI helpers

    var displayStatusText: String {
        switch status {
        case .idle(let lastCheckAt):
            guard let lastCheckAt else { return "Обновления ещё не проверялись" }
            return "Проверено \(Self.shortFormatter.string(from: lastCheckAt))"
        case .checking:
            return "Проверяю…"
        case .upToDate(let checkedAt):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return "\(version) — последняя. Проверено \(Self.shortFormatter.string(from: checkedAt))"
        case .available(let manifest):
            return "Доступна \(manifest.version)"
        case .downloading:
            return "Загружаю…"
        case .readyToInstall(_, let deferred):
            if !prefsService.updatesAutoInstall {
                return "Готово к установке"
            }
            return deferred ? "Установится при следующем запуске" : "Установится, когда вы перестанете печатать"
        case .installPendingSafeWindow:
            return "Установится через несколько секунд"
        case .installing:
            return "Устанавливаю…"
        case .feedStale(let validUntil, _):
            let days = max(0, Calendar.current.dateComponents([.day], from: validUntil, to: Date()).day ?? 0)
            return "Фид устарел (истёк \(days) дн. назад)"
        case .systemTooOld(let manifest, _):
            return "Есть \(manifest.version), нужна macOS ≥ \(manifest.minSystemVersion)"
        case .feedInvalid:
            return "Фид не прошёл проверку"
        case .identityMismatch:
            return "Обновление подписано иначе — скачайте с витрины"
        case .cannotInstallHere:
            return "Не могу обновить здесь — скачайте с витрины"
        case .networkError:
            return "Не удалось проверить обновления"
        }
    }

    /// MAJOR fix (security review): used to be true only for `.available` —
    /// once auto-check staged an update with auto-install OFF, status moved
    /// to `.readyToInstall` and NEITHER the window row nor the status-bar
    /// menu ever offered a way to actually install it, while the text
    /// claimed installation was imminent.
    var canOfferInstallButton: Bool {
        switch status {
        case .available, .readyToInstall: return true
        default: return false
        }
    }

    var availableManifest: UpdateManifest? {
        switch status {
        case .available(let manifest), .downloading(let manifest): return manifest
        case .readyToInstall(let manifest, _), .installPendingSafeWindow(let manifest): return manifest
        default: return nil
        }
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()
}
