import Foundation

struct ShiftTapResolver {
    enum Resolution: Equatable {
        case performSingleNow
        case waitForSecondTap
        case performDoubleNow
    }

    private(set) var hasPendingFirstTap = false

    mutating func registerTap(doubleShiftEnabled: Bool) -> Resolution {
        if doubleShiftEnabled, hasPendingFirstTap {
            hasPendingFirstTap = false
            return .performDoubleNow
        }
        if doubleShiftEnabled {
            hasPendingFirstTap = true
            return .waitForSecondTap
        }
        hasPendingFirstTap = false
        return .performSingleNow
    }

    mutating func expireFirstTap() -> Bool {
        guard hasPendingFirstTap else { return false }
        hasPendingFirstTap = false
        return true
    }

    mutating func cancel() {
        hasPendingFirstTap = false
    }
}
