import Foundation

/// JSON marker at `<updatesRoot>/.transaction`, written by whichever process
/// is currently swapping the installed bundle. Its presence is how a freshly
/// launched new version tells "I was just installed, carry on normally"
/// apart from "an install is still actively in flight, get out of the way"
/// (`UpdateStartupGuard`), and how a second `--install-update` invocation
/// avoids racing an already-running one (`UpdateInstallerMode`).
struct UpdateTransactionMarker: Codable, Equatable {
    /// `.syncing` — the helper is still copying files or about to. `.launching`
    /// — the sync (and its post-sync verification) already succeeded and the
    /// helper is about to `open()` the target; a fresh launch racing this
    /// marker should proceed normally rather than treat it as "still live"
    /// (CRITICAL fix, security review: the marker used to only ever get
    /// removed in a `defer` at `run()`'s return, which fires AFTER `open()`
    /// — a new process starting in that window saw a live marker and either
    /// quietly exited over a healthy launch, or raced the helper's own
    /// rollback). Old markers with no `phase` key decode as `.syncing` —
    /// fail closed.
    enum Phase: String, Codable { case syncing, launching }

    let helperPid: Int32
    let timestampEpoch: TimeInterval
    let target: String
    let stage: String
    var phase: Phase

    init(helperPid: Int32, timestampEpoch: TimeInterval, target: String, stage: String, phase: Phase = .syncing) {
        self.helperPid = helperPid
        self.timestampEpoch = timestampEpoch
        self.target = target
        self.stage = stage
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case helperPid, timestampEpoch, target, stage, phase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        helperPid = try container.decode(Int32.self, forKey: .helperPid)
        timestampEpoch = try container.decode(TimeInterval.self, forKey: .timestampEpoch)
        target = try container.decode(String.self, forKey: .target)
        stage = try container.decode(String.self, forKey: .stage)
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .syncing
    }

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
    /// treated as "in progress" and block a competing launch/transaction.
    /// `pidIsAlive` is injected since `kill(pid, 0)` isn't something a unit
    /// test can fake for an arbitrary pid.
    func isLive(now: TimeInterval, pidIsAlive: (Int32) -> Bool) -> Bool {
        phase == .syncing && now - timestampEpoch < Self.liveWindow && pidIsAlive(helperPid)
    }
}
