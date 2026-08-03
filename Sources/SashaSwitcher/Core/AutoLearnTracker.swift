import Foundation

struct LearnedCorrection: Equatable {
    let original: String
    let corrected: String
}

struct AutoLearnTracker {
    private enum State {
        case idle
        case awaitingDeletion(original: String, corrected: String, remaining: Int)
        case awaitingRetype(original: String, corrected: String)
    }

    private var state: State = .idle

    var isAwaitingRetype: Bool {
        if case .awaitingRetype = state { return true }
        return false
    }

    mutating func recordCorrection(original: String, corrected: String, trailing: String?) {
        guard !original.isEmpty, !corrected.isEmpty else {
            state = .idle
            return
        }
        state = .awaitingDeletion(
            original: original,
            corrected: corrected,
            remaining: corrected.count + (trailing?.count ?? 0)
        )
    }

    mutating func registerDeletion() {
        switch state {
        case .awaitingDeletion(let original, let corrected, let remaining):
            let next = remaining - 1
            if next <= 0 {
                state = .awaitingRetype(original: original, corrected: corrected)
            } else {
                state = .awaitingDeletion(
                    original: original, corrected: corrected, remaining: next
                )
            }
        case .awaitingRetype:
            state = .idle
        case .idle:
            break
        }
    }

    mutating func registerNonDeletion() {
        if case .awaitingDeletion = state { state = .idle }
    }

    mutating func confirmRetype(word: String, trailing: String?) -> LearnedCorrection? {
        defer { state = .idle }
        guard case .awaitingRetype(let original, let corrected) = state,
              trailing == " ",
              word.caseInsensitiveCompare(original) == .orderedSame else {
            return nil
        }
        return LearnedCorrection(original: original, corrected: corrected)
    }

    mutating func cancel() {
        state = .idle
    }
}
