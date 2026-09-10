import AppKit
import Foundation

// Headless test mode: `QwertySwitcher --test` runs unit tests and exits.
if CommandLine.arguments.contains("--test") {
    exit(Int32(TestRunner.run()))
}

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
