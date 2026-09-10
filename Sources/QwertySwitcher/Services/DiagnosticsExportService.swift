import Foundation

/// "Собрать отчёт" — a single zip in `~/Downloads` with the debug log
/// (per-key trace lines stripped) and a small `system.txt`, so a report can
/// be sent to the author without exposing anything that reconstructs what
/// was typed. Exceptions/learned words are deliberately NOT included.
final class DiagnosticsExportService {
    enum ExportError: Error { case zipFailed(Int32) }

    private let fileManager = FileManager.default

    @discardableResult
    func export(now: Date = Date()) throws -> URL {
        let stageDir = fileManager.temporaryDirectory
            .appendingPathComponent("QwertySwitcherReport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stageDir) }

        writeFilteredLog(name: "debug.log", source: DebugLog.shared.fileURL, into: stageDir)
        let rotated = DebugLog.shared.fileURL.deletingLastPathComponent().appendingPathComponent("debug.1.log")
        if fileManager.fileExists(atPath: rotated.path) {
            writeFilteredLog(name: "debug.1.log", source: rotated, into: stageDir)
        }
        try writeSystemInfo(into: stageDir)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "QwertySwitcher-report-\(formatter.string(from: now)).zip"
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = downloads.appendingPathComponent(name)
        try? fileManager.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", stageDir.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.zipFailed(process.terminationStatus) }
        return destination
    }

    /// Drops per-key trace lines (`key kc=`, `shift: kc=`) — the only lines
    /// the debug log carries that let the exact typed text be reconstructed
    /// keystroke by keystroke.
    static func filterReportLog(_ contents: String) -> String {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("key kc=") && !$0.contains("shift: kc=") }
            .joined(separator: "\n")
    }

    private func writeFilteredLog(name: String, source: URL, into directory: URL) {
        guard let raw = try? String(contentsOf: source, encoding: .utf8) else { return }
        let filtered = Self.filterReportLog(raw)
        try? filtered.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeSystemInfo(into directory: URL) throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()
        let prefs = PreferencesService()
        let perms = PermissionsService()
        let lines = [
            "Qwerty Switcher \(version) (\(build))",
            "macOS: \(os)",
            "Arch: \(arch)",
            "Accessibility: \(perms.hasAccessibility)",
            "Input Monitoring: \(perms.hasInputMonitoring)",
            "autoSwitch: \(prefs.isAutoSwitchEnabled)",
            "instantCorrection: \(prefs.isInstantCorrectionEnabled)",
            "singleShift: \(prefs.isSingleShiftEnabled)",
            "doubleShift: \(prefs.isDoubleShiftEnabled)",
            "capsLockSwitch: \(prefs.isCapsLockSwitchEnabled)",
            "learningEnabled: \(prefs.isLearningEnabled)",
            "gameModeEnabled: \(prefs.isGameModeEnabled)",
            "verboseLog: \(prefs.isVerboseLogEnabled)",
            "updatesAutoCheck: \(prefs.updatesAutoCheck)",
            "updatesAutoInstall: \(prefs.updatesAutoInstall)",
        ]
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8
        )
    }
}
