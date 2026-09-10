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
        case installing
        case feedStale(checkedAt: Date)
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
    private var checkTimer: Timer?
    private var windowRetryTimer: Timer?
    private var pendingStagedUpdate: UpdateStager.StagedUpdate?

    init(
        prefsService: PreferencesService,
        installedBundle: URL = Bundle.main.bundleURL,
        safetySnapshotProvider: @escaping () -> (idleSeconds: TimeInterval, gameModeActive: Bool, replacing: Bool),
        secureInputProvider: @escaping () -> Bool
    ) {
        self.prefsService = prefsService
        self.installedBundle = installedBundle
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        self.userAgent = "QwertySwitcher/\(version)"
        self.safetySnapshotProvider = safetySnapshotProvider
        self.secureInputProvider = secureInputProvider
        self.status = .idle(lastCheckAt: prefsService.updatesLastCheckAt)
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
    /// install-safety gates, only the schedule.
    func checkNow(userInitiated: Bool = true) {
        status = .checking
        let client = UpdateFeedClient(feedURLProvider: { [prefsService] in prefsService.updatesFeedURL }, userAgent: userAgent)
        client.fetchManifest { [weak self] result in
            DispatchQueue.main.async { self?.handleFeedResult(result) }
        }
    }

    /// Manual "Установить" — explicit user action, so it stages and installs
    /// right away rather than waiting for the idle/game-mode window that
    /// only gates the SILENT automatic path.
    func installAvailableUpdate() {
        guard case .available(let manifest) = status else { return }
        maybeStageAndInstall(manifest: manifest, userInitiated: true)
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
            let installedBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
            let outcome = UpdatePolicy.evaluate(
                manifest: manifest, installedBuild: installedBuild,
                lastSeenBuild: prefsService.updatesLastSeenBuild,
                currentSystemVersion: ProcessInfo.processInfo.operatingSystemVersion, now: now
            )
            DebugLog.shared.log("UPD", "check ok: build=\(manifest.build) outcome=\(outcome)")
            switch outcome {
            case .upToDate, .systemTooOld:
                status = .upToDate(checkedAt: now)
            case .feedStale:
                status = .feedStale(checkedAt: now)
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
            performInstall(staged: staged)
            return
        }
        guard prefsService.updatesAutoInstall else {
            status = .readyToInstall(staged.manifest, deferred: false)
            return
        }
        let snapshot = safetySnapshotProvider()
        let allowed = UpdatePolicy.shouldInstallNow(
            autoInstall: prefsService.updatesAutoInstall,
            idleSeconds: snapshot.idleSeconds, secureInput: secureInputProvider(),
            replacing: snapshot.replacing, gameModeActive: snapshot.gameModeActive
        )
        if allowed {
            performInstall(staged: staged)
        } else {
            status = .readyToInstall(staged.manifest, deferred: false)
            scheduleInstallWindowRetry(staged: staged)
        }
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
            let allowed = UpdatePolicy.shouldInstallNow(
                autoInstall: self.prefsService.updatesAutoInstall,
                idleSeconds: snapshot.idleSeconds, secureInput: self.secureInputProvider(),
                replacing: snapshot.replacing, gameModeActive: snapshot.gameModeActive
            )
            if allowed {
                timer.invalidate()
                self.performInstall(staged: staged)
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
            return deferred ? "Установится при следующем запуске" : "Установится, когда вы перестанете печатать"
        case .installing:
            return "Устанавливаю…"
        case .feedStale(let checkedAt):
            let days = Calendar.current.dateComponents([.day], from: checkedAt, to: Date()).day ?? 0
            return "Фид устарел (проверено \(days) дн. назад)"
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

    var canOfferInstallButton: Bool {
        if case .available = status { return true }
        return false
    }

    var availableManifest: UpdateManifest? {
        switch status {
        case .available(let manifest), .downloading(let manifest): return manifest
        case .readyToInstall(let manifest, _): return manifest
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
