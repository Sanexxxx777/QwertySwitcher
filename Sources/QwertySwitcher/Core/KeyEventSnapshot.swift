import CoreGraphics

/// A plain-value snapshot of the handful of scalar fields KeyboardMonitor's
/// hot path actually reads off a keydown/keyup CGEvent: keycode, flags,
/// autorepeat, keyboard type, and our own synthetic/replayed-event route.
/// Building this ONCE at the CGEventTap boundary (`eventTapCallback`) means
/// everything downstream — KeyboardMonitor's own analysis, and the headless
/// test harness — never touches a real CGEvent again. `init(type:event:)`
/// below is the only place in the app that reads a live CGEvent for the
/// keystroke-analysis path (the live tap and replay-building stay thin
/// adapters around it).
struct KeyEventSnapshot {
    let type: CGEventType
    let keycode: CGKeyCode
    let flags: CGEventFlags
    let autorepeat: Int64
    let keyboardType: Int64
    let route: EventRoute

    /// The only place that reads a live CGEvent — same four fields
    /// `QueuedUserEvent.init` used to read, plus the marker-derived route.
    init(type: CGEventType, event: CGEvent) {
        self.type = type
        keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        flags = event.flags
        autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
        keyboardType = event.getIntegerValueField(.keyboardEventKeyboardType)
        route = SyntheticEventMarker.route(event)
    }

    /// Memberwise, with defaults for the fields an ordinary test fixture
    /// doesn't care about — no CGEvent involved. Used by the headless test
    /// harness (`KeyboardMonitorHarness.press`) and by `asReplayed` below.
    init(
        type: CGEventType, keycode: CGKeyCode, flags: CGEventFlags = [],
        autorepeat: Int64 = 0, keyboardType: Int64 = 0, route: EventRoute = .physical
    ) {
        self.type = type
        self.keycode = keycode
        self.flags = flags
        self.autorepeat = autorepeat
        self.keyboardType = keyboardType
        self.route = route
    }

    /// Moved verbatim from the old `QueuedUserEvent.makeEvent()` — builds a
    /// real CGEvent for replay and marks it so the event tap routes it as
    /// `.replayedUser`, never `.ours` or `.physical`.
    func makeEvent() -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keycode,
            keyDown: type != .keyUp
        ) else { return nil }
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
        SyntheticEventMarker.markAsReplayedUserEvent(event)
        return event
    }

    /// Same fields, re-routed as a replayed user event — what a queued
    /// keystroke becomes the moment it is handed back to `handle(_:)` after
    /// the pause that queued it ends (production: the real event tap reading
    /// its own replayed CGEvent's marker; the test harness: `pendingReplays`).
    var asReplayed: KeyEventSnapshot {
        KeyEventSnapshot(
            type: type, keycode: keycode, flags: flags,
            autorepeat: autorepeat, keyboardType: keyboardType, route: .replayedUser
        )
    }
}
