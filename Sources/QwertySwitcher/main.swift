import AppKit
import Foundation

// Headless test mode: `QwertySwitcher --test` runs unit tests and exits.
#if DEBUG
if TestRunMode.isActive {
    exit(Int32(TestRunner.run()))
}
#endif

// Update-installer helper mode: this is the SAME binary, launched from the
// staged copy of a downloaded release (see UpdateInstallerMode). Runs and
// exits before any NSApplication/UI exists.
if CommandLine.arguments.contains("--install-update") {
    exit(UpdateInstallerMode.run())
}

// A freshly-installed build that starts while its own install transaction is
// still (briefly) marked live — e.g. `open` racing the helper's own
// bookkeeping right after the swap — exits quietly instead of running a
// second, spurious copy.
if !UpdateStartupGuard.shouldProceedWithNormalLaunch() {
    exit(0)
}

// Only one copy of the app may run per user session (field incident
// 23.09.2026 — three copies ran at once, each correcting the owner's text
// independently). The fd must stay open for the rest of the process
// lifetime — never close it — so it lives in this top-level `let`.
let singleInstanceLockFD: Int32?
switch SingleInstanceLock.acquire(at: SingleInstanceLock.defaultURL) {
case .busy(let holderPid):
    let holderText = holderPid.map { "pid \($0)" } ?? "unknown pid"
    DebugLog.shared.log("APP", "another copy is already running (\(holderText)) — this one exits")
    DebugLog.shared.waitForPendingWrites()
    exit(0)
case .unavailable(let code):
    DebugLog.shared.log("APP", "single-instance lock unavailable (errno \(code)) — starting anyway")
    singleInstanceLockFD = nil
case .locked(let fd):
    singleInstanceLockFD = fd
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
