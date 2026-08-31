import Foundation
import AppKit

/// Pure, static probes for "is this a game" — no AppKit dependency, unit
/// testable without touching NSWorkspace/Bundle for real. `GameModeState` is
/// the only production caller (spec's detection scheme, Layer 0); it passes
/// the real `Bundle(url:).infoDictionary`/`bundleURL.path` it read on
/// activation.
enum GameAppProbe {
    /// `LSApplicationCategoryType` test: exact `public.app-category.games`,
    /// or any structural `…-games` subcategory (`action-games`,
    /// `word-games`, `role-playing-games`, ...) — a structural rule instead
    /// of an enumerated subcategory list, since Apple's subcategory set can
    /// grow (spec §1).
    static func isGameCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        if category == "public.app-category.games" { return true }
        return category.hasPrefix("public.app-category.") && category.hasSuffix("-games")
    }

    /// Layer 0 declaration check (spec §1): category, OR either the macOS
    /// (`LSSupportsGameMode`, macOS 26+) or GameKit (`GCSupportsGameMode`)
    /// Info.plist flag, OR a Steam install path (`/steamapps/` — Steam
    /// always installs games there). One read per app per session — the
    /// caller (`GameModeState`) does this only on activation, never on the
    /// hot path.
    static func declaredGame(infoDictionary: [String: Any]?, bundlePath: String?) -> Bool {
        if isGameCategory(infoDictionary?["LSApplicationCategoryType"] as? String) {
            return true
        }
        if (infoDictionary?["LSSupportsGameMode"] as? Bool) == true {
            return true
        }
        if (infoDictionary?["GCSupportsGameMode"] as? Bool) == true {
            return true
        }
        if let bundlePath, bundlePath.contains("/steamapps/") {
            return true
        }
        return false
    }
}

/// Runtime "is the frontmost app a game right now" state machine (spec §5).
/// Per-bundleID state lives in memory; two verdicts survive on disk —
/// `gameModeDenied` (permanent "this is not a game", set from the UI) and
/// `gameModeAuto` (a bundleID recognized ≥3 times in one session, so the
/// NEXT activation recognizes it from the first keystroke instead of
/// waiting on a fresh behavioral signal).
///
/// `isActive(bundleID:)` and `note(_:)` touch only in-memory dictionaries/
/// sets and the injected `now`/`isEnabled` closures — no `UserDefaults`,
/// `Bundle`, or `NSWorkspace` call appears in either body, because both are
/// called from the `CGEventTap` callback (hot path). All AppKit reads
/// (Info.plist, frontmost bundleID) happen once per activation, in
/// `noteActivation`/the `didActivateApplicationNotification` observer that
/// feeds it — the same off-hot-path caching pattern `LanguageDetector`'s
/// junk-override app cache already uses (`LanguageDetector.swift:96`).
final class GameModeState {
    // `PreferencesService()` is cheap (a thin `UserDefaults` wrapper, no
    // caching — same pattern `MainView` already uses for a fresh read of
    // `themePreference`), so a new instance per query is fine here; it keeps
    // this the single legal one-line wiring point instead of introducing a
    // second `PreferencesService` singleton just for this closure.
    static let shared = GameModeState(isEnabled: { PreferencesService().isGameModeEnabled })

    /// A single-signal behavioral trigger sufficient to enter GAME on its
    /// own (spec §5 table) — logged verbatim as `ev=<rawValue>`.
    enum Evidence: String {
        case longRun
        case heldKeys
    }

    /// Where the current GAME verdict for a bundleID came from — logged
    /// verbatim (`declared`/`persisted`) except `.behavioral`, which the
    /// spec's log format spells `behavior`.
    private enum ModeSource {
        case declared
        case persisted
        case behavioral
    }

    /// UNKNOWN / GAME / TYPING from spec §5. DENIED is deliberately NOT a
    /// case here — it is modeled as a separate, permanently-persisted set
    /// (`deniedSet`) rather than a transient per-session mode, because it
    /// must survive TTL expiry, termination, and re-declaration alike ("режим
    /// больше не включается" — nothing about the ordinary session lifecycle
    /// should be able to clear it).
    private enum Mode {
        case unknown
        case game(source: ModeSource)
        case typing
    }

    private struct BundleState {
        var mode: Mode = .unknown
        /// Evidence notes received this session (declared/persisted entries
        /// don't count) — gates the `gameModeAuto` persist at deactivation.
        var evidenceCountThisSession = 0
        var proseWordCount = 0
        var proseWindowStart: Date?
        /// Set when this bundleID stops being frontmost; cleared again on
        /// reactivation. `nil` while frontmost or never yet deactivated.
        var deactivatedAt: Date?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    /// Mirrors `PreferencesService.isGameModeEnabled` (wired via `.shared`'s
    /// default argument above) — checked only at the
    /// `isActive`/`isActiveForFrontmost` query boundary,
    /// deliberately not inside `noteActivation`/`note`/`noteProseWord`:
    /// those keep tracking state unconditionally, so flipping the toggle
    /// back on reflects whatever is already true of the frontmost app
    /// immediately, without waiting for a fresh activation event.
    private let isEnabled: () -> Bool

    private let deniedKey = AppIdentity.keyPrefix + "gameModeDenied"
    private let autoKey = AppIdentity.keyPrefix + "gameModeAuto"
    private let autoCap = 50
    private let ttl: TimeInterval = 30 * 60
    private let proseWindow: TimeInterval = 30
    private let proseWordThreshold = 4
    private let proseWordMinLength = 4
    private let persistEvidenceThreshold = 3

    private var states: [String: BundleState] = [:]
    private var deniedSet: Set<String> = []
    /// bundleID -> lastSeen. Persisted verdict; cap 50, LRU by `lastSeen`.
    private var autoVerdicts: [String: Date] = [:]
    /// Cached frontmost bundleID — the only thing `note`/`noteProseWord`
    /// read to know which app's state to touch.
    private var currentAppBundleID: String?

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         isEnabled: @escaping () -> Bool = { true }) {
        self.defaults = defaults
        self.now = now
        self.isEnabled = isEnabled
        load()
        currentAppBundleID = Self.isTestBinary ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Same signal `InputSourceManager.isTestBinary`/`LanguageDetector`
    /// use — the real frontmost app at test-binary launch is ambient,
    /// uncontrolled state that must never leak into a deterministic run.
    private static var isTestBinary: Bool {
        CommandLine.arguments.contains("--test")
    }

    // MARK: - AppKit-facing (off hot path)

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        let infoDictionary = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        noteActivation(bundleID: bundleID, infoDictionary: infoDictionary, bundlePath: app.bundleURL?.path)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        states.removeValue(forKey: bundleID)
    }

    /// Called on every app activation — production via the observer above
    /// (which supplies the real Info.plist/path), tests directly (bypassing
    /// NSWorkspace/Bundle entirely, since this method itself never touches
    /// them — `GameAppProbe` is a pure function of what's passed in).
    ///
    /// Resolves the entering app's mode in priority order: denied (no-op) >
    /// declared (Layer 0) > persisted (`gameModeAuto`) > leave UNKNOWN,
    /// waiting for a behavioral `note(_:)`. Also treats the PREVIOUS
    /// frontmost bundleID (if different) as just having deactivated.
    func noteActivation(bundleID: String, infoDictionary: [String: Any]?, bundlePath: String?) {
        if let previous = currentAppBundleID, previous != bundleID {
            deactivate(bundleID: previous)
        }
        currentAppBundleID = bundleID
        pruneExpired()

        guard !deniedSet.contains(bundleID) else { return }

        var state = states[bundleID] ?? BundleState()
        state.deactivatedAt = nil
        let wasGame = isGameMode(state.mode)

        if GameAppProbe.declaredGame(infoDictionary: infoDictionary, bundlePath: bundlePath) {
            state.mode = .game(source: .declared)
            state.proseWordCount = 0
            state.proseWindowStart = nil
            states[bundleID] = state
            if !wasGame { log("game mode ON app=\(bundleID) src=declared") }
            return
        }

        if autoVerdicts[bundleID] != nil {
            state.mode = .game(source: .persisted)
            state.proseWordCount = 0
            state.proseWindowStart = nil
            states[bundleID] = state
            if !wasGame { log("game mode ON app=\(bundleID) src=persisted") }
            return
        }

        states[bundleID] = state
    }

    // MARK: - Hot path (CGEventTap callback) — memory reads/increments only

    /// Notes a single behavioral clue for the frontmost app. One clue is
    /// always enough to (re)enter GAME — from UNKNOWN (first-time
    /// recognition) or from TYPING (hysteresis, spec §5). Any clue also
    /// resets the prose-exit counter, whether or not it changed the mode.
    func note(_ evidence: Evidence) {
        guard let bundleID = currentAppBundleID, !deniedSet.contains(bundleID) else { return }
        var state = states[bundleID] ?? BundleState()
        state.evidenceCountThisSession += 1
        state.proseWordCount = 0
        state.proseWindowStart = nil
        let wasGame = isGameMode(state.mode)
        if !wasGame {
            state.mode = .game(source: .behavioral)
        }
        states[bundleID] = state
        if !wasGame {
            log("game mode ON app=\(bundleID) src=behavior ev=\(evidence.rawValue)")
        }
    }

    /// Notes a word crossing the boundary while the frontmost app is in
    /// GAME — a no-op unless the word itself qualifies as "prose" (spec
    /// §5: dictionary word, core ≥4 letters, no held-key autorepeat) and the
    /// app is actually in GAME (nothing to exit from UNKNOWN/TYPING). Four
    /// qualifying words within a rolling 30s window flip GAME -> TYPING.
    func noteProseWord(isDictionaryWord: Bool, len: Int, hasHeldKeys: Bool) {
        guard let bundleID = currentAppBundleID else { return }
        guard var state = states[bundleID], isGameMode(state.mode) else { return }
        guard isDictionaryWord, len >= proseWordMinLength, !hasHeldKeys else { return }

        let t = now()
        if let start = state.proseWindowStart, t.timeIntervalSince(start) > proseWindow {
            state.proseWordCount = 0
            state.proseWindowStart = nil
        }
        if state.proseWordCount == 0 {
            state.proseWindowStart = t
        }
        state.proseWordCount += 1

        guard state.proseWordCount >= proseWordThreshold else {
            states[bundleID] = state
            return
        }
        state.mode = .typing
        state.proseWordCount = 0
        state.proseWindowStart = nil
        states[bundleID] = state
        log("game mode OFF app=\(bundleID) reason=prose")
    }

    // MARK: - Queries

    func isActive(bundleID: String?) -> Bool {
        guard isEnabled(), let bundleID, !deniedSet.contains(bundleID) else { return false }
        guard let state = states[bundleID] else { return false }
        if let deactivatedAt = state.deactivatedAt, now().timeIntervalSince(deactivatedAt) > ttl {
            return false
        }
        return isGameMode(state.mode)
    }

    func isActiveForFrontmost() -> Bool {
        isActive(bundleID: currentAppBundleID)
    }

    /// Wave-3 "Распознанные игры" list wiring: bundle IDs currently in GAME
    /// this session (not yet deactivated long enough to earn a persisted
    /// verdict) UNION the persisted verdicts themselves — a session's first
    /// two-clue game wouldn't show up at all if this only read
    /// `autoVerdicts` (persist needs 3 clues, spec §5). Denied bundleIDs
    /// never appear in either source (`deny` removes both). Pure read of
    /// existing state, no automaton change. Sorted for stable UI ordering.
    var recognizedGames: [String] {
        let sessionGames = states.compactMap { bundleID, state in
            isGameMode(state.mode) ? bundleID : nil
        }
        return Array(Set(sessionGames).union(autoVerdicts.keys)).sorted()
    }

    // MARK: - Denial (UI/menu action — not hot path)

    /// Permanently marks `bundleID` as "not a game" — overrides declared,
    /// persisted, and behavioral recognition alike until reversed (there is
    /// no reversal API in v1; the spec's list UI is the only undo surface,
    /// planned for wave 3). Persists immediately: this is a rare, deliberate
    /// user action, not hot-path traffic.
    func deny(_ bundleID: String) {
        guard deniedSet.insert(bundleID).inserted else { return }
        states.removeValue(forKey: bundleID)
        autoVerdicts.removeValue(forKey: bundleID)
        persistDenied()
        saveAuto()
        log("game mode OFF app=\(bundleID) reason=denied")
    }

    // MARK: - Helpers

    private func isGameMode(_ mode: Mode) -> Bool {
        if case .game = mode { return true }
        return false
    }

    /// Marks `bundleID` as no longer frontmost: persists the session's
    /// verdict if it earned it (≥3 clues total — declared/persisted entries
    /// don't count, only `note(_:)` calls do), then starts its TTL clock.
    /// This — not `note`/`noteProseWord` — is the one write to disk, and it
    /// only ever runs from an activation-notification callback, never from
    /// the CGEventTap callback.
    private func deactivate(bundleID: String) {
        guard var state = states[bundleID] else { return }
        if state.evidenceCountThisSession >= persistEvidenceThreshold {
            persistAutoVerdict(bundleID: bundleID)
        }
        state.deactivatedAt = now()
        states[bundleID] = state
    }

    private func pruneExpired() {
        let t = now()
        let expiredIDs = states.compactMap { bundleID, state -> String? in
            guard let deactivatedAt = state.deactivatedAt, t.timeIntervalSince(deactivatedAt) > ttl else { return nil }
            return bundleID
        }
        for bundleID in expiredIDs {
            states.removeValue(forKey: bundleID)
        }
    }

    private func persistAutoVerdict(bundleID: String) {
        autoVerdicts[bundleID] = now()
        enforceAutoCap()
        saveAuto()
    }

    private func enforceAutoCap() {
        while autoVerdicts.count > autoCap {
            guard let oldest = autoVerdicts.min(by: { $0.value < $1.value }) else { break }
            autoVerdicts.removeValue(forKey: oldest.key)
        }
    }

    private func saveAuto() {
        let payload = autoVerdicts.mapValues { $0.timeIntervalSince1970 }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: autoKey)
    }

    private func persistDenied() {
        defaults.set(Array(deniedSet), forKey: deniedKey)
    }

    private func load() {
        if let data = defaults.data(forKey: autoKey),
           let payload = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            autoVerdicts = payload.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if let deniedArray = defaults.array(forKey: deniedKey) as? [String] {
            deniedSet = Set(deniedArray)
        }
    }

    private func log(_ event: String) {
        DebugLog.shared.log("GM", event)
    }
}
