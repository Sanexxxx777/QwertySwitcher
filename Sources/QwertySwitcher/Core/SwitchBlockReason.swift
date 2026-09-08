import Foundation

/// Single source of truth for "why can't Qwerty Switcher switch layouts right
/// now" — resolved from the same two signals `StatusBarController` already
/// reads (`KeyboardMonitor.health`, `PreferencesService.isAutoSwitchEnabled`).
/// Consumed by the status-bar badge color, the grey diagnostic line in the
/// menu and the tooltip, so all three always agree instead of re-deriving the
/// same logic three times.
enum SwitchBlockReason: Equatable {
    case none
    case secureInput(appName: String?)
    case missingPermissions
    case interceptionStopped
    case autoSwitchDisabled
    /// The 0.7.0 per-app profile (`ExceptionsService.AppProfile`) blocks
    /// something for the frontmost app specifically — everything else (tap,
    /// global toggle, license) is fine. Without this case the badge/menu/
    /// tooltip went silent here (`.none`) even though nothing actually
    /// happens while typing in that app, which reads as "broken" rather than
    /// "configured off for this app".
    case blockedForApp(AppProfileBlockKind, appName: String?)

    /// Game Mode (gamemode-spec-20260831.md) silenced correction for the
    /// frontmost app — checked LAST, even after `blockedForApp`: a per-app
    /// profile block is a DELIBERATE user setting and the more complete
    /// explanation of "nothing happens here" when both are somehow true at
    /// once, same reasoning `resolve()` already applies between the global
    /// checks and `blockedForApp` itself.
    case gameDetected(appName: String?)

    enum AppProfileBlockKind: Equatable {
        case autoSwitch
        case instantCorrectionOnly
    }

    /// Human-readable Russian line. `nil` for `.none` — "everything is fine"
    /// is expressed by the ABSENCE of a line, never a reassuring filler.
    var title: String? {
        switch self {
        case .none:
            return nil
        case .secureInput(let appName):
            guard let appName else { return "Ввод пароля — переключение приостановлено" }
            return "Пароль в \(appName) — переключение приостановлено"
        case .missingPermissions:
            return "Нет разрешения Универсального доступа"
        case .interceptionStopped:
            return "Перехват клавиш остановлен"
        case .autoSwitchDisabled:
            return "Автопереключение выключено"
        case .blockedForApp(let kind, let appName):
            let app = appName ?? "этого приложения"
            switch kind {
            case .autoSwitch:
                return "Автопереключение выключено для \(app)"
            case .instantCorrectionOnly:
                return "Мгновенная коррекция выключена для \(app)"
            }
        case .gameDetected:
            return "Игра — коррекция приостановлена"
        }
    }

    var blocksSwitching: Bool { self != .none }

    /// Priority mirrors how urgently each cause needs attention: a hard stop
    /// (missing permissions / event tap down) always wins over a soft one
    /// (auto-switch toggled off), and secure input — a deliberately
    /// transient, self-resolving pause — is checked first since it needs no
    /// user action at all. The per-app profile block is checked LAST and
    /// only reported when nothing more global already explains the
    /// silence — no point saying "off for Terminal" when auto-switch is off
    /// everywhere anyway. `autoSwitch` outranks `instantCorrectionOnly`
    /// within the app-profile case itself: a full block is the more complete
    /// explanation of "nothing happens here".
    static func resolve(
        health: EventTapHealth,
        isAutoSwitchEnabled: Bool,
        secureInputAppName: String?,
        appProfileBlock: (kind: AppProfileBlockKind, appName: String?)? = nil,
        // A single labeled-tuple field (`(appName: String?)`) isn't legal
        // Swift — it collapses to a plain `String?` and loses the label —
        // so "is game mode blocking this app" and "its name, if known" are
        // two params instead of `appProfileBlock`'s one-tuple shape.
        gameDetected: Bool = false, gameAppName: String? = nil
    ) -> SwitchBlockReason {
        switch health {
        case .secureInput:
            return .secureInput(appName: secureInputAppName)
        case .missingPermissions:
            return .missingPermissions
        case .starting, .unavailable, .stopped:
            return .interceptionStopped
        case .running:
            break
        }
        guard isAutoSwitchEnabled else { return .autoSwitchDisabled }
        if let appProfileBlock {
            return .blockedForApp(appProfileBlock.kind, appName: appProfileBlock.appName)
        }
        if gameDetected {
            return .gameDetected(appName: gameAppName)
        }
        return .none
    }
}
