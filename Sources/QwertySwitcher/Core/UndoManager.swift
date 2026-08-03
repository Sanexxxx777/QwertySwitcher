import Foundation

/// Undo last auto-switch (like Punto Switcher Ctrl+Z)
/// Stores the last correction so it can be reversed
final class SwitchUndoManager {
    struct Correction {
        let originalKeycodes: [UInt16]
        let originalWord: String
        let correctedWord: String
        let trailing: String?
        let originalLayoutID: String
        let targetLayoutID: String
    }

    private(set) var lastCorrection: Correction?

    func record(originalKeycodes: [UInt16], originalWord: String, correctedWord: String,
                trailing: String?, originalLayoutID: String, targetLayoutID: String) {
        lastCorrection = Correction(
            originalKeycodes: originalKeycodes,
            originalWord: originalWord,
            correctedWord: correctedWord,
            trailing: trailing,
            originalLayoutID: originalLayoutID,
            targetLayoutID: targetLayoutID
        )
    }

    var canUndo: Bool {
        lastCorrection != nil
    }

    func consume() -> Correction? {
        let c = lastCorrection
        lastCorrection = nil
        return c
    }

    func invalidate() {
        lastCorrection = nil
    }
}
