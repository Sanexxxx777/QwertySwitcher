import Foundation

/// The one place that decides "this process is the headless test suite".
/// Release builds contain no tests (see `Tests/` — wrapped in `#if DEBUG`),
/// so there the answer is always `false`, whatever arguments were passed.
enum TestRunMode {
    static let isActive: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--test")
        #else
        return false
        #endif
    }()
}
