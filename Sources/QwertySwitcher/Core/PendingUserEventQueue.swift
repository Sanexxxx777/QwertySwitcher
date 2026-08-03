import Foundation

/// An ordered queue for user keystrokes captured while a text replacement is
/// in flight (KeyboardMonitor.isPaused). Extracted as a pure, GUI-free type so
/// its ordering rules are unit-testable directly:
/// - `enqueue` — real typing that arrives during the pause queues at the back,
///   to be replayed in order once the replacement finishes.
/// - `enqueueFront` — a trigger keystroke we suppressed ourselves (to avoid a
///   race with our own backspaces, RC-1) goes to the FRONT, so it replays
///   first if the replacement ultimately fails.
/// - `discardFront` — on success the suppressed trigger must not be replayed
///   (its contribution is already part of the typed correction) — discard it
///   without disturbing anything queued behind it.
/// - `drain` — hand back everything in order and empty the queue, used to
///   replay on any outcome (including the suppressed trigger when it wasn't
///   discarded).
struct PendingUserEventQueue<Element> {
    private(set) var items: [Element] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func enqueue(_ item: Element) {
        items.append(item)
    }

    mutating func enqueueFront(_ item: Element) {
        items.insert(item, at: 0)
    }

    mutating func discardFront() {
        guard !items.isEmpty else { return }
        items.removeFirst()
    }

    mutating func drain() -> [Element] {
        defer { items.removeAll(keepingCapacity: true) }
        return items
    }
}
