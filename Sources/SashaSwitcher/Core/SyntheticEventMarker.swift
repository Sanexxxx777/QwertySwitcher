import CoreGraphics

enum SyntheticEventMarker {
    // Process-local marker used only to distinguish Qwerty Switch-generated
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
}
