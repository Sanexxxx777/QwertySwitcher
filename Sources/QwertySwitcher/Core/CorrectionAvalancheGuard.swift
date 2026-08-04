import Foundation

/// Circuit breaker against a self-triggering correction feedback loop.
///
/// Root cause (CLAUDE.md "avalanche" incident, live evidence: typing a
/// Russian word rendered as `завершftm` on screen, ~10 layout switches and 4
/// Double Shift firings inside ONE second — physically impossible for a
/// human): `KeyboardMonitor` deliberately still analyzes REPLAYED user
/// keystrokes (RC-2 — a replayed space must still close a word boundary),
/// which means an auto-fired correction can, through its own aftermath,
/// feed another correction with no real human action in between.
///
/// This guard doesn't try to be the ONLY fix for that (see
/// `KeyboardMonitor.queueIfReplacementActive`, which stops queueing/replaying
/// `.flagsChanged` — the concrete mechanism that fed `HotkeyManager`'s
/// Shift-tap gesture detector a squashed-timing burst) — it's a second,
/// independent line of defense that caps how many auto-corrections may fire
/// back to back with no genuinely physical keystroke landing between them,
/// regardless of whatever mechanism is driving the loop this time.
struct CorrectionAvalancheGuard {
    private(set) var consecutiveWithoutPhysicalInput = 0
    let limit: Int

    init(limit: Int = 3) {
        self.limit = limit
    }

    /// Call for every genuinely physical (not replayed, not our own
    /// synthetic) event `KeyboardMonitor.handleEvent` processes — proof a
    /// human actually did something between corrections.
    mutating func registerPhysicalEvent() {
        consecutiveWithoutPhysicalInput = 0
    }

    /// True while it's still safe to fire another auto-correction.
    var canFire: Bool { consecutiveWithoutPhysicalInput < limit }

    /// Call exactly when an auto-correction actually commits to firing
    /// (right before `textReplacer.replaceCurrentWord`/an equivalent).
    mutating func recordFired() {
        consecutiveWithoutPhysicalInput += 1
    }
}
