#if DEBUG
import Foundation

/// `TerminalApps` is the single terminal list shared by `LanguageDetector`
/// (junk-override, island, game mode) and `ExceptionsService` (fresh-install
/// blocked apps). Pins the invariants the two old copies broke.
enum TerminalAppsTests {
    static func run() {
        TestRunner.section("TerminalApps — single terminal list")

        TestRunner.assertTrue(
            TerminalApps.bundleIDs.contains("org.alacritty") && TerminalApps.bundleIDs.contains("io.alacritty"),
            "both Alacritty bundle ids (org./io.) are terminals"
        )
        TestRunner.assertTrue(
            TerminalApps.bundleIDs.contains("com.mitchellh.ghostty"),
            "Ghostty is a terminal"
        )
        TestRunner.assertTrue(
            !TerminalApps.defaultBlockedBundleIDs.contains("com.mitchellh.ghostty"),
            "Ghostty is NOT blocked by default — the owner wants corrections there"
        )
        let strays = TerminalApps.defaultBlockedBundleIDs.filter { !TerminalApps.bundleIDs.contains($0) }
        TestRunner.assertTrue(
            strays.isEmpty,
            "every default-blocked id is also in bundleIDs (strays: \(strays))"
        )
        TestRunner.assertTrue(
            LanguageDetector.isTerminalBundle("io.alacritty") && LanguageDetector.isTerminalBundle("org.alacritty"),
            "LanguageDetector.isTerminalBundle reads TerminalApps.bundleIDs"
        )
    }
}
#endif
