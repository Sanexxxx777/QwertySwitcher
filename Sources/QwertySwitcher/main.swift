import AppKit
import Foundation

// Headless test mode: `QwertySwitcher --test` runs unit tests and exits.
if CommandLine.arguments.contains("--test") {
    exit(Int32(TestRunner.run()))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
