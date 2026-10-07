import Foundation

/// The one list of terminal/editor bundle ids (`ax=none` class — CLAUDE.md "ax=none").
/// Before this existed, `LanguageDetector` and `ExceptionsService` each kept
/// their own copy and disagreed (Alacritty spelled `org.alacritty` in one,
/// `io.alacritty` in the other) — both spellings live here now.
enum TerminalApps {
    /// Every app treated as a terminal: junk-override is off there,
    /// behavioral game-mode entry is off there, and the island obeys
    /// `PreferencesService.isIslandInTerminalsEnabled`.
    static let bundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "net.kovidgoyal.kitty",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    /// Seed for `ExceptionsService`'s app profiles on a fresh install
    /// (auto-switch blocked). A subset of `bundleIDs`: Ghostty, Warp, VS Code
    /// and Cursor are deliberately NOT blocked — the owner wants corrections
    /// in Ghostty (the «сдуфк»→clear case lives there).
    static let defaultBlockedBundleIDs: [String] = [
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.googlecode.iterm2",
        "io.alacritty",
        "org.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
    ]
}
