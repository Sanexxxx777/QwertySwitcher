import CoreGraphics

enum SyntheticEventMarker {
    // Process-local marker used only to distinguish Qwerty Switcher-generated
    // keystrokes from real hardware input in the event tap.
    static let value: Int64 = 0x5353_5749_5443_4845
    private static let replayedUserValue: Int64 = 0x5353_4852_504C_4159

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }

    static func markAsReplayedUserEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: replayedUserValue)
    }

    static func isReplayedUserEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == replayedUserValue
    }

    static func shouldBypass(_ event: CGEvent) -> Bool {
        isMarked(event) || isReplayedUserEvent(event)
    }

    static func route(_ event: CGEvent) -> EventRoute {
        .classify(isMarked: isMarked(event), isReplayedUser: isReplayedUserEvent(event))
    }
}

/// Where a keydown event came from, derived from the two independent markers
/// above. Kept as a pure enum (decoupled from CGEvent) so the routing rules
/// fixed by RC-2 are unit-testable without a live GUI session:
/// - `.ours` — our own synthetic backspace/retype keystroke. Bypasses all
///   analysis (buffer, word boundary, queueing) — it never happened as far
///   as KeyboardMonitor is concerned.
/// - `.replayedUser` — a real keystroke we captured while a replacement was
///   in flight and are now replaying. Must be analyzed exactly like live
///   typing (a replayed space is still a word boundary) but never re-queued.
/// - `.physical` — genuine live hardware input.
enum EventRoute: Equatable {
    case ours
    case replayedUser
    case physical

    static func classify(isMarked: Bool, isReplayedUser: Bool) -> EventRoute {
        if isMarked { return .ours }
        if isReplayedUser { return .replayedUser }
        return .physical
    }
}
