import Foundation

/// Single source of truth for "why can't Qwerty Switcher switch layouts right
/// now" — resolved from the same three signals `StatusBarController` already
/// reads (`KeyboardMonitor.health`, `PreferencesService.isAutoSwitchEnabled`,
/// `LicenseService.isEntitled`). Consumed by the status-bar badge color, the
/// grey diagnostic line in the menu and the tooltip, so all three always
/// agree instead of re-deriving the same logic three times.
enum SwitchBlockReason: Equatable {
    case none
    case secureInput(appName: String?)
    case missingPermissions
    case interceptionStopped
    case autoSwitchDisabled
    case subscriptionExpired

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
        case .subscriptionExpired:
            return "Подписка истекла"
        }
    }

    var blocksSwitching: Bool { self != .none }

    /// Priority mirrors how urgently each cause needs attention: a hard stop
    /// (missing permissions / event tap down) always wins over a soft one
    /// (auto-switch toggled off / license lapsed), and secure input — a
    /// deliberately transient, self-resolving pause — is checked first since
    /// it needs no user action at all.
    static func resolve(
        health: EventTapHealth,
        isAutoSwitchEnabled: Bool,
        isEntitled: Bool,
        secureInputAppName: String?
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
        guard isEntitled else { return .subscriptionExpired }
        return .none
    }
}
