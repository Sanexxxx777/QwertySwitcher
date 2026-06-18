# SashaSwitcher — Architecture (v0.2.0)

Нативное macOS приложение для автоматического переключения раскладки клавиатуры.
Работает как menu-bar app (без Dock), перехватывает нажатия через CGEventTap,
определяет язык набираемого слова и при необходимости переключает раскладку
и исправляет текст. Аналог Caramba Switcher / Punto Switcher, но локальный и без телеметрии.

## Tech Stack

| Компонент | Технология | Обоснование |
|-----------|-----------|-------------|
| Язык | Swift 5.9+ | Производительный (lookup < 1μs на BloomFilter) |
| UI | AppKit + SwiftUI | AppKit для `NSStatusItem`, SwiftUI для окон |
| Сборка | SPM + bash | `swift build` + `./Scripts/build.sh` → .app, без Xcode |
| Словарь | BloomFilter (≈480 KB) + `NSSpellChecker` подтверждение | Минимум RAM (≈7 MB total) |
| Перехват клавиш | `CGEventTap` (ListenOnly) | Единственный API; не блокирует события |
| Раскладки | `TIS` (`TISCopyCurrentKeyboardInputSource`, `UCKeyTranslate`) | Единственный Apple API |
| Хранение | `UserDefaults` + cached `.ssbf` в `~/Library/Application Support/SashaSwitcher/` | Просто и надёжно |

## File Structure

```
SashaSwitcher/
├── Package.swift
├── Sources/SashaSwitcher/
│   ├── main.swift                        — entry point + `--test` mode
│   ├── AppDelegate.swift                 — wire-up, onboarding
│   ├── Core/
│   │   ├── KeyboardMonitor.swift         — CGEventTap + word buffer + correction
│   │   ├── HotkeyManager.swift           — Single/Double Shift, L+R, CapsLock
│   │   ├── LanguageDetector.swift        — 4-level scoring
│   │   ├── InputBuffer.swift             — ring buffer 64, keycode classification
│   │   ├── InputSourceManager.swift      — TIS wrappers, layout change notifications
│   │   ├── TextReplacer.swift            — backspace + unicode type
│   │   ├── UndoManager.swift             — SwitchUndoManager (Cmd+Option+Z)
│   │   ├── SecureInputDetector.swift     — password field detection
│   │   ├── NGramAnalyzer.swift           — forbidden/common bigrams RU/EN
│   │   └── WordFrequency.swift           — top-200 common-word bonus
│   ├── Dictionary/
│   │   ├── BloomFilter.swift             — FNV-1a double hashing + disk format (SSBF)
│   │   └── WordDictionary.swift          — bloom + NSSpellChecker, cached to disk
│   ├── UI/
│   │   ├── StatusBarController.swift     — menu bar item (shows layout RU/EN)
│   │   └── Views/
│   │       ├── MainView.swift            — Gamma-themed main window
│   │       ├── MainViewModel.swift
│   │       ├── AboutView.swift
│   │       ├── ExceptionsView.swift      — word/app/auto-learned tabs
│   │       ├── OnboardingView.swift      — Accessibility + Input Monitoring
│   │       ├── SwitchPopup.swift         — floating bubble near cursor
│   │       └── StatusIndicator.swift     — top-right ✓/✗ toggle indicator
│   ├── Models/
│   │   └── Language.swift                — KeyboardLayout, DetectionResult
│   ├── Services/
│   │   ├── StatisticsService.swift       — counters + time-saved formula
│   │   ├── PreferencesService.swift
│   │   ├── ExceptionsService.swift       — word/app/auto-learned
│   │   ├── PermissionsService.swift      — AX + InputMonitoring prompts
│   │   ├── PerAppLayoutService.swift     — bundle ID → layout memory
│   │   ├── YoficatorService.swift        — е → ё rules
│   │   ├── SoundService.swift            — Tink/Pop/Basso, respects toggle
│   │   ├── AutoStartService.swift        — SMAppService login item
│   │   └── PrivacyService.swift          — audit UserDefaults for keylog keys
│   └── Tests/TestRunner.swift            — standalone runner (`--test`)
├── Resources/
│   ├── Dictionaries/{en_US,ru_RU}.txt    — 714K words bundled
│   ├── Info.plist                        — v0.2.0 build 2, LSUIElement
│   └── AppIcon.icns
├── Scripts/
│   ├── build.sh                          — release .app bundle
│   └── test.sh                           — debug build + --test
└── build/SashaSwitcher.app                — output (9.8 MB)
```

## Core Pipeline

```
CGEventTap (listenOnly)
    │
    ├── flagsChanged ── HotkeyManager
    │     ├─ Left+Right Shift → toggle auto-switch
    │     ├─ Single Shift tap → switch layout (→ different-language first)
    │     ├─ Double Shift tap → swapLastWordInBuffer() → clipboard fallback
    │     └─ CapsLock → switch layout
    │
    └── keyDown ── KeyboardMonitor
          │
          ├── filter: cooldown, modifiers, secure input, app exception, Spotlight
          ├── stale buffer eviction (>10s idle → clear)
          │
          ├── Cmd+Option+Z → Undo last correction
          ├── Cmd+Shift+V  → Paste plain text
          │
          ├── Backspace → buffer.removeLast + auto-learn tracking
          │
          ├── Space (49) → processCurrentWord() + clear   [triggers correction]
          ├── Enter/Tab/Esc → clear buffer only           [no correction: chat-safe]
          │
          ├── Punctuation in EN layout (. , ; ' [ ] `) → processCurrentWord + clear
          ├── Letter key → buffer.append
          └── Number/slash → processCurrentWord + clear
```

### LanguageDetector scoring

```
for each installed layout L:
    word = convertKeycodes(buffer, toLayout: L)
    skip if mixed script or matches skipPatterns (URL, email, hex, camelCase)
    score =   80..100 if BloomFilter + NSSpellChecker confirm (strong)
            + 62..70  if only NSSpellChecker (weak)
            + n-gram bonus/penalty (±50)
            + frequency bonus (+25 for top-200 word)
            + context bias (+15 if matches previous word's language)
            + current-layout tiebreaker (+5)

candidates = layouts with score > 0, sorted desc
if candidates[0].layout == current            → noSwitch
if score gap < 10                             → noSwitch (ambiguous)
otherwise                                      → switchTo
```

### Text replacement

1. `sendBackspaces(count: wordLength)` — keycode 51 × N
2. `TISSelectInputSource(targetLayout)` on main thread
3. `typeStringFast(corrected)` — `keyboardSetUnicodeString` in chunks of 20

Each step separated by 2.5 ms to avoid dropped events in slow apps.

## Hotkey summary

| Shortcut | Action |
|----------|--------|
| Single Shift (tap) | Next layout (prefers different-language) |
| Double Shift (tap × 2 < 350 ms) | Convert last word (uses internal buffer, clipboard fallback) |
| Left+Right Shift | Toggle auto-switching (✓/✗ top-right indicator) |
| CapsLock | Switch layout |
| Cmd+Shift+V | Paste without formatting |
| Cmd+Option+Z | Undo last auto-switch (2s window) |

## Permissions

1. **Accessibility** — for CGEventTap + TextReplacer
2. **Input Monitoring** — for CGEventTap keycode reading

Onboarding window (`OnboardingView`) appears on launch if either is missing.
Buttons call both `request*()` (system prompt) and `open*Settings()` fallback.

## Privacy

- 100% local processing, no network calls
- No keystroke logging
- `PrivacyService.auditStorage()` on launch scans UserDefaults for suspicious keys
- BloomFilter cache stored only in `~/Library/Application Support/SashaSwitcher/`

## Testing

```bash
./Scripts/test.sh    # builds + runs --test mode, prints pass/fail
```

43 assertions across BloomFilter, Yoficator, NGram, InputBuffer, Exceptions.
XCTest not used (Command Line Tools only, no Xcode required).

## Build

```bash
swift build                       # debug
./Scripts/build.sh                # release .app bundle (9.8 MB)
open build/SashaSwitcher.app      # launch
```
