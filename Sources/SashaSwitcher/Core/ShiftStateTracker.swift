import Foundation

struct ShiftStateTracker {
    enum Transition: Equatable {
        case none
        case down
        case up
        case suppressedRelease
    }

    private(set) var leftDown = false
    private(set) var rightDown = false
    private var suppressedReleases: Set<UInt16> = []

    var anyDown: Bool { leftDown || rightDown }
    var bothDown: Bool { leftDown && rightDown }

    mutating func transition(keycode: UInt16, aggregateShiftPressed: Bool) -> Transition {
        guard keycode == 56 || keycode == 60 else { return .none }

        if suppressedReleases.remove(keycode) != nil {
            return .suppressedRelease
        }

        let isLeft = keycode == 56
        let trackedDown = isLeft ? leftDown : rightDown
        if trackedDown {
            if isLeft { leftDown = false } else { rightDown = false }
            return .up
        }
        guard aggregateShiftPressed else { return .none }
        if isLeft { leftDown = true } else { rightDown = true }
        return .down
    }

    mutating func suppressComboReleases() {
        leftDown = false
        rightDown = false
        suppressedReleases = [56, 60]
    }
}
