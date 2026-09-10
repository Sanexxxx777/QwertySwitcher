import Foundation

/// JSON marker at `<updatesRoot>/.transaction`, written by whichever process
/// is currently swapping the installed bundle. Its presence is how a freshly
/// launched new version tells "I was just installed, carry on normally"
/// apart from "an install is still actively in flight, get out of the way"
/// (`UpdateStartupGuard`), and how a second `--install-update` invocation
/// avoids racing an already-running one (`UpdateInstallerMode`).
struct UpdateTransactionMarker: Codable, Equatable {
    let helperPid: Int32
    let timestampEpoch: TimeInterval
    let target: String
    let stage: String

    static let liveWindow: TimeInterval = 5 * 60

    static func markerURL(updatesRoot: URL = UpdateStager.updatesRootDirectory()) -> URL {
        updatesRoot.appendingPathComponent(".transaction")
    }

    static func read(at url: URL) -> UpdateTransactionMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UpdateTransactionMarker.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Pure: whether this marker still describes an install that should be
    /// treated as "in progress". `pidIsAlive` is injected since `kill(pid,
    /// 0)` isn't something a unit test can fake for an arbitrary pid.
    func isLive(now: TimeInterval, pidIsAlive: (Int32) -> Bool) -> Bool {
        now - timestampEpoch < Self.liveWindow && pidIsAlive(helperPid)
    }
}
