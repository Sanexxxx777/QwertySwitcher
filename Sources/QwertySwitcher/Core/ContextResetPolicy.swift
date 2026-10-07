import Foundation

// One table for "the editing context ended behind our back" (plan 007).
//
// KeyboardMonitor keeps a model of what is typed (buffer, run, leading symbols,
// history, sentence tracker, island ring, learning trackers...). Every event
// below drops a DIFFERENT part of it, deliberately (a stale pause keeps the
// history and the armed sentence start; an external layout switch keeps the
// learning tracker and the undo record, ...). The matrix lives here as data,
// `KeyboardMonitor.resetTypingContext` applies it. A new "context ended" event
// = a new `ContextResetReason` + one row in the policy test, never a hand list
// at the call site.
//
// Pure: no KeyboardMonitor reference, no stored state.

/// Why the typed-word model is being dropped.
enum ContextResetReason: Equatable {
    /// The layout was switched by something other than us (and the first-burst retype declined).
    case externalLayoutChange
    /// A secure input field has focus.
    case secureInput
    /// The user paused typing longer than the stale-buffer timeout (whole seconds, as logged).
    case stale(seconds: Int)
    /// Backspace: the buffer EDIT and the conditional sentence rule stay at the call site.
    case backspace
    /// A navigation key moved the caret (the key code, as logged).
    case navigationKey(UInt16)
    /// App activated, mouse click, modifier shortcut, paste-no-format, blocked-app hotkey.
    case editingInvalidated(String)
    /// `undoLastCorrection` pre-replacement block.
    case undo

    /// The `reason=` value of the `buffer wiped:` field-log line. Frozen format.
    /// `.secureInput` and `.undo` log no wipe today; their labels are for diagnostics only.
    var logLabel: String {
        switch self {
        case .externalLayoutChange: return "layout-changed-externally"
        case .secureInput: return "secure-input"
        case .stale(let seconds): return "stale-\(seconds)s"
        case .backspace: return "backspace"
        case .navigationKey(let keycode): return "navigation-key-\(keycode)"
        case .editingInvalidated(let reason): return reason
        case .undo: return "undo"
        }
    }

    /// Whether the executor calls `logContextWipe`. False for secure input and undo (no wipe line
    /// today) and for backspace (its site keeps a narrower condition: `logContextWipe` alone
    /// would fire on every Backspace with a non-empty buffer).
    var logsWipe: Bool {
        switch self {
        case .secureInput, .undo, .backspace: return false
        case .externalLayoutChange, .stale, .navigationKey, .editingInvalidated: return true
        }
    }
}

/// One bit per component the executor can reset. `chordComma` is NOT a bit: both of its sites
/// run before an early return and stay where they are.
struct ContextResetScope: OptionSet {
    let rawValue: Int

    /// `buffer.clear()` (backspace EDITS the buffer at its site instead).
    static let wordModel = ContextResetScope(rawValue: 1 << 0)
    /// `pendingLeadingSymbols`, `runKeystrokes`, `wordAutorepeatCount`.
    static let runAndLead = ContextResetScope(rawValue: 1 << 1)
    /// `lastCompletedWord = nil`.
    static let history = ContextResetScope(rawValue: 1 << 2)
    /// `autoLearnTracker.cancel()`.
    static let autoLearn = ContextResetScope(rawValue: 1 << 3)
    /// `switchUndoManager.invalidate()`.
    static let undoRecord = ContextResetScope(rawValue: 1 << 4)
    /// `instantCorrectionGate.reset()`.
    static let instantGate = ContextResetScope(rawValue: 1 << 5)
    /// `sentenceStartTracker.reset()` (backspace applies its own conditional rule at the site).
    static let sentence = ContextResetScope(rawValue: 1 << 6)
    /// `languageDetector.resetContext()`.
    static let detectorContext = ContextResetScope(rawValue: 1 << 7)
    /// `feedbackTracker.reset()` (Mechanism B).
    static let feedback = ContextResetScope(rawValue: 1 << 8)
    /// `pendingIslandRestore`, `pendingIslandTarget`, `pendingIslandContext`.
    static let island = ContextResetScope(rawValue: 1 << 9)
}

enum ContextResetPolicy {
    /// The matrix of plan 007. Deliberate "-" cells: stale keeps history/sentence/detector,
    /// extLayout keeps autoLearn and the undo record, secure/stale/nav keep the instant gate.
    static func scope(for reason: ContextResetReason) -> ContextResetScope {
        switch reason {
        case .externalLayoutChange:
            return [.wordModel, .runAndLead, .history, .instantGate, .sentence, .detectorContext,
                    .feedback, .island]
        case .secureInput:
            return [.wordModel, .runAndLead, .history, .autoLearn, .sentence, .detectorContext,
                    .feedback, .island]
        case .stale:
            return [.wordModel, .runAndLead, .feedback, .island]
        case .backspace:
            return [.runAndLead, .history, .undoRecord, .instantGate, .feedback, .island]
        case .navigationKey:
            return [.wordModel, .runAndLead, .history, .autoLearn, .undoRecord, .sentence,
                    .detectorContext, .feedback, .island]
        case .editingInvalidated:
            return [.wordModel, .runAndLead, .history, .autoLearn, .undoRecord, .instantGate,
                    .sentence, .detectorContext, .feedback, .island]
        case .undo:
            return [.detectorContext, .feedback, .island]
        }
    }
}
