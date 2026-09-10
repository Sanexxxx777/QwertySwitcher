# Qwerty Switcher

Native macOS keyboard layout auto-switcher. If you type in two languages on the
same physical keyboard — most commonly Russian on a ЙЦУКЕН/QWERTY layout — you've
hit this: your fingers type the right word, but the OS is on the wrong layout,
so `привет` comes out as `ghbdtn`. Qwerty Switcher watches keystrokes system-wide,
figures out which language you actually meant, and retypes the word in the
correct layout automatically.

It's a from-scratch macOS analog of Punto Switcher / Caramba Switcher: menu-bar
only (no Dock icon). All typing analysis is 100% local — keystrokes never
leave the Mac. Network is used only if you enable update checks: once a day
the app fetches a single JSON from shulgin.is-a.dev and sends nothing about
you (see Privacy below). Free and offline since 0.10.0 — no license/trial.

## How it works

- **`CGEventTap`** (`.listenOnly`, session tap with an HID-level fallback)
  intercepts every keydown / flags-changed event system-wide — the same
  low-level mechanism used by hotkey managers and accessibility tools.
- Each candidate word is scored against every installed keyboard layout by a
  **4-level detector**:
  1. Bloom filter membership check (714K-word combined EN+RU dictionary,
     ~480 KB in memory, FNV-1a double hashing)
  2. `NSSpellChecker` fallback for words outside the bundled dictionary
  3. N-gram scoring (common/forbidden letter bigrams per language)
  4. Word-frequency bonus + a context bias toward the previous word's language
- On a confident match, the word is erased with synthetic backspace events and
  retyped through `TISSelectInputSource` + `UCKeyTranslate`, one character per
  `CGEvent` — batching more than that silently drops keystrokes in
  Electron-based apps (Slack, Discord, VS Code, Telegram).
- A ring buffer plus a short-lived "last completed word" slot let the Double
  Shift hotkey convert a word you already finished typing, even after
  auto-correct already fired on it.
- Per-app profiles independently disable auto-switching, instant correction,
  or hotkeys. Auto-switching can also be paused for 15, 60, or 120 minutes.
- Local text snippets expand after a word boundary, and optional smart case
  fixes accidental `ПРивет` capitalization and sentence starts.
- Settings, exceptions, app profiles, learned pairs, snippets, and per-app
  layouts can be exported to a validated, versioned JSON backup. License and
  diagnostic state are deliberately excluded.

Full pipeline, scoring formula and file layout: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Hotkeys

| Shortcut | Action |
|---|---|
| Single Shift (tap) | Switch to the next layout |
| Double Shift (tap × 2, < 600 ms) | Convert the last typed word |
| Left+Right Shift | Toggle auto-switching on/off |
| CapsLock | Switch layout |
| Cmd+Shift+V | Paste without formatting |
| Cmd+Option+Z | Undo last correction |

## Stack

- Swift 6, Swift Package Manager only — no Xcode project file, `swift build`
  is enough
- AppKit for the menu-bar item, SwiftUI for the windows
- `CGEventTap`, Carbon's Text Input Sources (`TIS…`), `UCKeyTranslate` — raw
  event-level key interception, not the Accessibility-API text-replacement
  route most "typing helper" apps use
- Custom Bloom filter with its own binary cache format (`.ssbf`) instead of
  pulling in a dependency for a lookup structure this small
- Standalone test runner (`QwertySwitcher --test`) — no XCTest/Xcode required
  to run the suite

## Build & run

```bash
git clone https://github.com/Sanexxxx777/QwertySwitcher.git
cd QwertySwitcher
swift build                     # debug build
./Scripts/test.sh               # unit tests, no Xcode needed
./Scripts/build.sh              # release .app bundle
open "build/Qwerty Switcher.app"
```

First launch asks for **Accessibility** and **Input Monitoring** permissions
(System Settings → Privacy & Security) — `CGEventTap` needs both to see and
replay keystrokes. Running `./Scripts/setup-signing.sh` once creates a
persistent self-signed code-signing identity so those permissions survive
rebuilds during development instead of resetting on every `swift build`.

Requires macOS 13+. Building a full macro-enabled SwiftUI build needs Xcode
(or its full toolchain) — plain Command Line Tools alone can't resolve the
`@State`/`@Observable` macro plugins.

Code signing, notarization and the App Store distribution path (blocked today
by `CGEventTap` being incompatible with the App Sandbox) are documented in
[`docs/SIGNING.md`](docs/SIGNING.md).

The voice-input decision and release gates are in
[`docs/VOICE_SPIKE.md`](docs/VOICE_SPIKE.md).

## Privacy

All typing analysis runs locally: no analytics, no keystroke logging.
Free and offline since 0.10.0 — there is no license/trial/subscription
network traffic anymore.

Network is used only if you enable update checks: once a day the app fetches
a single JSON manifest from shulgin.is-a.dev and sends nothing about you (no
identifier, no telemetry). Installing an update stays a separate, manual
opt-in toggle. See [`docs/SIGNING.md`](docs/SIGNING.md) for how that manifest
is signed and verified before anything is installed.

`PrivacyService` audits `UserDefaults` on launch for anything that looks like
it could be leaking typed text.

## About this repo

Most of my other public work is trading infrastructure and automation in
Python. This project is deliberately different: a systems-level macOS app —
raw event taps, keyboard layout APIs, a hand-rolled binary cache format for
the dictionary — with no framework doing the hard part for you.

— [Aleksandr Shulgin](https://github.com/Sanexxxx777) (@Aleksandr_NFA)
