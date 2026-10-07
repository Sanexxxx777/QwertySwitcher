#if DEBUG
import Foundation

/// Shared reader for the source-contract guards that pin `KeyboardMonitor`'s code structurally.
/// `KeyboardMonitor` lives in three files (plan 008): the guards read all of them, in a fixed
/// order, so a marker or a forbidden statement is found wherever the move put it.
enum SourceContract {
    /// `Core/KeyboardMonitor.swift`, then `+DoubleShift`, then `+KeyRouting`, joined by `\n`.
    /// nil when ANY of the three is unreadable — the caller must FAIL, never skip.
    static func keyboardMonitorSources() -> String? {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // QwertySwitcher/
            .appendingPathComponent("Core")
        var parts: [String] = []
        for name in ["KeyboardMonitor.swift", "KeyboardMonitor+DoubleShift.swift", "KeyboardMonitor+KeyRouting.swift"] {
            guard let text = try? String(contentsOf: core.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }
}
#endif
