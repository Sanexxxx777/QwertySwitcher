import Foundation

enum EventTapHealth: Equatable {
    case missingPermissions
    case starting
    case running
    case secureInput
    case unavailable
    case stopped

    var title: String {
        switch self {
        case .missingPermissions: return "Нужны разрешения"
        case .starting: return "Запуск перехвата…"
        case .running: return "Перехват работает"
        case .secureInput: return "Защищённое поле — пауза"
        case .unavailable: return "Перехват недоступен"
        case .stopped: return "Перехват остановлен"
        }
    }

    var isOperational: Bool { self == .running }
}

extension Notification.Name {
    static let eventTapHealthChanged = Notification.Name(
        AppIdentity.keyPrefix + "eventTapHealthChanged"
    )
}
