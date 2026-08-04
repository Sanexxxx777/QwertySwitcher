import Foundation

/// Pure onboarding state machine — no AppKit, no SwiftUI, no timers.
///
/// Extracted so the "which permissions are granted → what do we show" decision
/// is testable. The window/level/activation problems that hid the onboarding
/// window behind System Settings live in `OnboardingWindowController`; this
/// type only decides what the visible window should say.
enum OnboardingStep: Equatable {
    /// Accessibility is missing. It comes first because Input Monitoring is
    /// effectively derived from it (`CGPreflightListenEventAccess()` returns
    /// true once Accessibility is granted), so asking for it first is noise.
    case grantAccessibility
    /// Accessibility is in place, Input Monitoring still isn't.
    case grantInputMonitoring
    /// Both granted, the event tap just hasn't come up yet. Normal for a second
    /// or two — the app polls and re-arms itself without a restart.
    case verifying
    /// Both granted but the interception is still down past the grace window.
    /// This is the ONLY state where restarting the app actually helps.
    case stalled
    /// Both granted and the interception is running.
    case ready
}

struct OnboardingStatus: Equatable {
    var hasAccessibility: Bool
    var hasInputMonitoring: Bool
    /// Event tap is live (running, or paused only because of a secure field).
    var isInterceptionRunning: Bool
    /// Seconds since both permissions were first seen granted; nil while one
    /// of them is still missing.
    var secondsSinceAllGranted: TimeInterval?

    init(hasAccessibility: Bool,
         hasInputMonitoring: Bool,
         isInterceptionRunning: Bool,
         secondsSinceAllGranted: TimeInterval? = nil) {
        self.hasAccessibility = hasAccessibility
        self.hasInputMonitoring = hasInputMonitoring
        self.isInterceptionRunning = isInterceptionRunning
        self.secondsSinceAllGranted = secondsSinceAllGranted
    }

    var hasAllPermissions: Bool { hasAccessibility && hasInputMonitoring }
}

enum OnboardingStateMachine {
    /// The app re-arms the event tap on a 1s poll. Anything past this is not
    /// "still starting", it's stuck — measured recovery on this Mac was <1s
    /// after the grant landed.
    static let restartGraceSeconds: TimeInterval = 8

    static func step(for status: OnboardingStatus) -> OnboardingStep {
        guard status.hasAccessibility else { return .grantAccessibility }
        guard status.hasInputMonitoring else { return .grantInputMonitoring }
        if status.isInterceptionRunning { return .ready }
        let waited = status.secondsSinceAllGranted ?? 0
        return waited >= restartGraceSeconds ? .stalled : .verifying
    }

    /// The window may be dismissed by "Далее" only once both grants are in.
    /// Deliberately does NOT require a live event tap: the permissions are what
    /// onboarding is about, and the tap self-heals on the health poll.
    static func canFinish(_ step: OnboardingStep) -> Bool {
        switch step {
        case .grantAccessibility, .grantInputMonitoring: return false
        case .verifying, .stalled, .ready:               return true
        }
    }

    /// Restarting is offered only in `.stalled`. Everywhere else it would be a
    /// lie: permission grants are picked up inside the running process (proven
    /// in debug.log — `perms accessibility=false` → `[KM] event tap started`
    /// 30s later, same PID, no restart).
    static func offersRestart(_ step: OnboardingStep) -> Bool { step == .stalled }

    /// Which permission the primary action button should chase, if any. Used to
    /// avoid re-prompting for something that is already granted.
    static func pendingPermission(for status: OnboardingStatus) -> PendingPermission? {
        if !status.hasAccessibility { return .accessibility }
        if !status.hasInputMonitoring { return .inputMonitoring }
        return nil
    }

    enum PendingPermission: Equatable { case accessibility, inputMonitoring }

    static func hint(for step: OnboardingStep) -> String {
        switch step {
        case .grantAccessibility:
            return "Открой «Универсальный доступ» и включи Qwerty Switcher — окно останется на виду."
        case .grantInputMonitoring:
            return "Осталось Input Monitoring. macOS может предложить «Завершить и открыть снова» — жми «Позже»."
        case .verifying:
            return "Разрешения на месте — включаю перехват…"
        case .stalled:
            return "Разрешения выданы, но перехват не поднялся. Здесь помогает перезапуск приложения."
        case .ready:
            return "Всё готово — перехват работает. Нажми «Далее»."
        }
    }
}
