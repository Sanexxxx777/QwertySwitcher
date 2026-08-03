import Foundation

/// Compact debug logger. Writes to `~/Library/Logs/QwertySwitcher/debug.log`.
/// Rotates when file exceeds 1 MB (keeps last ~10 KB). Privacy-first:
/// we log metadata (lengths, language codes, scores, event kinds) — never the word itself.
final class DebugLog {
    static let shared = DebugLog()

    private let fm = FileManager.default
    private let url: URL
    private let queue = DispatchQueue(label: AppIdentity.keyPrefix + "debuglog", qos: .utility)
    private let maxBytes = 1_000_000          // rotate at 1 MB
    private let keepTailBytes = 10_000        // retain the last 10 KB after rotation
    private let iso: ISO8601DateFormatter
    private let compact: DateFormatter

    private init() {
        let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/QwertySwitcher", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        url = logsDir.appendingPathComponent("debug.log")

        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        compact = DateFormatter()
        compact.dateFormat = "HH:mm:ss.SSS"
        compact.locale = Locale(identifier: "en_US_POSIX")

        // Mark app start
        write(module: "APP", event: "---- session start \(iso.string(from: Date())) ----")
    }

    /// Compact log line: `HH:mm:ss.SSS [MOD] event`
    func log(_ module: String, _ event: String) {
        queue.async { [weak self] in
            self?.write(module: module, event: event)
        }
    }

    /// Synchronously fetch the current log contents (for the "Show logs" menu).
    var currentContents: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var fileURL: URL { url }

    // MARK: - Private

    private func write(module: String, event: String) {
        let line = "\(compact.string(from: Date())) [\(module)] \(event)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }

        // Append
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }

        // Rotate if oversized
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            rotate()
        }
    }

    private func rotate() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let total = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let offset = UInt64(max(0, total - keepTailBytes))
        try? handle.seek(toOffset: offset)
        let tail = (try? handle.readToEnd()) ?? Data()
        let marker = "---- rotated \(iso.string(from: Date())) ----\n".data(using: .utf8) ?? Data()
        try? (marker + tail).write(to: url)
    }
}
