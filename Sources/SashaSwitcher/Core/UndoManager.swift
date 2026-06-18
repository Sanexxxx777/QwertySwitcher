import Foundation

/// Undo last auto-switch (like Punto Switcher Ctrl+Z)
/// Stores the last correction so it can be reversed
final class SwitchUndoManager {
    struct Correction {
        let originalKeycodes: [UInt16]
        let originalWord: String
        let correctedWord: String
        let originalLayoutID: String
        let targetLayoutID: String
        let timestamp: CFAbsoluteTime
    }

    private(set) var lastCorrection: Correction?
    private let maxAge: CFAbsoluteTime = 2.0 // undo available for 2 seconds (short to avoid Cmd+Z conflicts)

    func record(originalKeycodes: [UInt16], originalWord: String, correctedWord: String,
                originalLayoutID: String, targetLayoutID: String) {
        lastCorrection = Correction(
            originalKeycodes: originalKeycodes,
            originalWord: originalWord,
            correctedWord: correctedWord,
            originalLayoutID: originalLayoutID,
            targetLayoutID: targetLayoutID,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    var canUndo: Bool {
        guard let c = lastCorrection else { return false }
        return CFAbsoluteTimeGetCurrent() - c.timestamp < maxAge
    }

    func consume() -> Correction? {
        guard canUndo else {
            lastCorrection = nil
            return nil
        }
        let c = lastCorrection
        lastCorrection = nil
        return c
    }
}
