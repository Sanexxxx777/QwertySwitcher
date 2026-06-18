# SashaSwitcher — macOS Keyboard Layout Auto-Switcher

Нативное macOS приложение для автоматического переключения раскладки клавиатуры (аналог Caramba Switcher).

## Tech Stack
- Swift 6.3, SwiftUI + AppKit, SPM (без Xcode)
- CGEventTap (перехват клавиш), TIS API (раскладки), UCKeyTranslate (маппинг)
- BloomFilter + NSSpellChecker (словарь 714K слов, ~1MB RAM)

## Structure
```
Sources/SashaSwitcher/
├── main.swift, AppDelegate.swift
├── Core/          — KeyboardMonitor, LanguageDetector, TextReplacer, HotkeyManager,
│                    InputBuffer, InputSourceManager, SecureInputDetector,
│                    NGramAnalyzer, WordFrequency, UndoManager
├── Dictionary/    — BloomFilter, WordDictionary
├── UI/Views/      — MainView (Gamma theme), AboutView, ExceptionsView,
│                    SwitchPopup, StatusIndicator
├── UI/Components/ — (встроены в MainView: GammaStatCard, GammaToggle, ThemeButton)
├── Models/        — Language
├── Services/      — Statistics, Preferences, Permissions, Sound, AutoStart,
│                    Exceptions, Yoficator, PerAppLayout, Privacy
Resources/Dictionaries/ — en_US.txt (370K), ru_RU.txt (343K)
Scripts/build.sh        — сборка .app bundle
```

## Build, Test & Run
```bash
swift build                     # debug (0.1s cached)
./Scripts/test.sh               # 43 unit tests via --test mode
./Scripts/build.sh              # release .app (arm64 only, 11MB)
./Scripts/make-dmg.sh           # universal (arm64+x86_64) .app + DMG для distribution
open build/SashaSwitcher.app    # запуск
```

Debug logs: `~/Library/Logs/SashaSwitcher/debug.log` (rotation at 1MB).
Menu → "Показать логи" / "Открыть папку логов".

## Key Features
- 4-level scoring: Dictionary + SpellCheck + N-gram + WordFrequency + Context
- Hotkeys: Single Shift, Double Shift, L+R Shift toggle (✅/❌ indicator), CapsLock, Cmd+Shift+V, **Cmd+Option+Z** undo
- Minimum word length 3 (avoids false positives on 2-letter particles)
- Liquid Glass UI (NFA design system, dark only — auto appearance)
- Per-app layout memory, exceptions (word + app + auto-learn with per-entry delete), Ёфикатор
- Onboarding window — shown on first launch, auto-detects granted permissions via Timer polling; user confirms via "Далее"
- Secure input detection, Spotlight skip, 300ms self-capture cooldown
- Context reset on layout change (manual or by bot)
- Privacy: 100% local, 0 telemetry, audit on launch

## Signing & Distribution (see docs/SIGNING.md)
- **Stage 1 (current):** persistent self-signed identity "SashaSwitcher Developer" in login keychain → stable CDHash → TCC permissions survive rebuilds. Run once: `./Scripts/setup-signing.sh` (asks for login password once to unlock keychain + set partition list). Free.
- **Stage 2:** Developer ID + notarization for DMG distribution ($99/year Apple Developer Program). Scripts ready (`build.sh developerid` + `notarize.sh`).
- **Stage 3:** App Store — blocked by CGEventTap being incompatible with App Sandbox. Requires rewrite to IMKit (Input Method Kit) or Accessibility-only API.

## Version 0.2.0 (2026-04-22 full audit)

### Correctness
- Info.plist + UI version synced to 0.2.0 (was stale 0.1.0)
- Stats cards show distinct values per feature (time-saved formula from counts)
- Yoficator: removed incorrect "вышел → вышёл" (stress on "ы", no ё)
- Dictionary ru_RU.txt: removed 19 garbage fragments
- Fixed clipped AboutView / ExceptionsView windows
- UI sounds (Tink) respect isSoundEnabled everywhere
- Version now read from Bundle

### Reliability of correction
- **Double Shift** uses KeyboardMonitor's internal buffer (was fragile clipboard hack)
- Clipboard fallback tracks `NSPasteboard.changeCount` (was blind 100ms wait)
- **Enter/Tab/Esc no longer trigger correction** — backspaces would land on empty
  input field in chat apps. Only Space + punctuation trigger correction.
- Stale buffer eviction (10s idle → clear)
- Punctuation context-aware: `. , ; '` are boundary in en, letters in ru
- Single Shift dedupes layouts (prefers different languageCode)
- Min word length 3 (was 2 — false positives on "it", "oo")
- Cmd+Z → Cmd+Option+Z (avoid conflict with host app undo)
- resetContext on layout change
- `TISSelectInputSource` failures logged

### UX
- StatusBar icon: EN / RU / ⁓ (paused), was just "S"
- Onboarding window if Accessibility or Input Monitoring missing
- Explicit system prompts (`AXIsProcessTrustedWithOptions`, `CGRequestListenEventAccess`)
- Popup "↩ → UNDO" → "↺ Отмена"
- Per-entry delete in auto-learned exceptions
- Bottom "ВЕРСИЯ" button is now clickable (opens About)

### Infrastructure
- Standalone test runner: `SashaSwitcher --test` → 43 tests (no XCTest required)
- `DebugLog.shared` → `~/Library/Logs/SashaSwitcher/debug.log`
  - Modules: APP, KM (KeyboardMonitor), HK (HotkeyManager), IS (InputSource)
  - Compact format `HH:mm:ss.SSS [MOD] event`
  - Rotation at 1MB → keeps last 10KB
  - Privacy: logs metadata only (lengths, langs), never the word
- Menu bar: "Показать логи" / "Открыть папку логов"
- ARCHITECTURE.md fully rewritten

### Metrics
- Bundle: 9.9 MB, ad-hoc signed
- swift build: 0 warnings
- Tests: 43/43 passed
- RAM: ~7MB, startup ~0.4s (cached bloom)

## Open for live testing
- Double Shift in real apps (TG, Safari, VSCode, Terminal)
- Onboarding flow post-fresh-permissions
- StatusBar EN/RU update on manual layout switch
- Buffer timeout in real long pauses
- Regressions → check `~/Library/Logs/SashaSwitcher/debug.log`

## Known bugs
1. ~~**Double Shift не всегда срабатывает с первого раза**~~ ✅ 2026-04-23: Bug A — self-capture отменял `pendingSingleShift`. Перенёс `isPaused/inCooldown` гейты ДО `markKeyPressed`.
2. **Лишняя английская буква при автозамене** — Саша напечатал "привет ghbdtn<SPACE>", получил `"привет gпривет"` (одна `g` осталась нетронутой, остальные 5 букв `hbdtn` backspace'нулись и заменились на `привет`). Вероятно race condition: `InputBuffer` пропустил первую букву либо `TextReplacer` выдал меньше backspaces чем длина слова. Возможно связано с self-capture cooldown (300ms) — начало слова попало в окно. Диагностика: снять debug.log, сверить `[KM] buffer add` count с фактически введённым словом
3. **Регистр теряется при автокоррекции** — `UCKeyTranslate(modifierKeys=0)` в `InputSourceManager.convertKeycodes` всегда отдаёт lowercase. "Hello" после коррекции становится "hello". Fix: пробрасывать Shift-state в `InputBuffer` для каждой keycode и передавать в `UCKeyTranslate`.
4. **Одновременное удержание обоих Shifts** — когда оба зажаты и один отпускают, `shiftPressed` всё ещё true (из-за оставшегося) → код интерпретирует release как повторный press. В типичном сценарии маскируется combo-веткой, но edge case остаётся.

## v0.2.0 tweak (2026-04-24) — Popup убран, TTL снят
По просьбе Саши:
- **Popup «EN → RU» убран**. Вызовы `SwitchPopupController.shared.show(...)` / `showUndo()` удалены из `KeyboardMonitor.swift` (автокоррекция, Double Shift, Undo). Сам класс `SwitchPopup.swift` оставлен, просто не вызывается — если захочется вернуть, достаточно раскомментировать 3 строки.
- **5-секундный TTL истории снят**. В `swapLastWordInBuffer` убрана проверка `CFAbsoluteTimeGetCurrent() - last.timestamp < lastWordTTL` — Double Shift срабатывает на последнее введённое слово сколько угодно времени спустя (пока юзер не начал печатать новое слово / не сделал успешную конвертацию, после чего `lastCompletedWord = nil`). «Один раз на слово» сохраняется — никаких других лимитов нет.
- StatusIndicator (✅/❌ для L+R Shift toggle) не трогал — это индикатор переключения автокоррекции, не смены раскладки.
- 51/51 тестов, build 0 warnings, .app 11 MB.

## v0.2.0 hotfix (2026-04-23) — Double Shift fix
Симптомы от Саши: двойной Shift перестал работать. Либо **стирает слово** и ничего не вставляет, либо **сдвигает курсор влево** без изменений.

**Root cause (два независимых бага):**
- **«стирает»** = `TextReplacer.typeStringFast` батчил юникод по 20 символов в один CGEvent. Electron/веб-приложения (Telegram, Discord, VSCode, Slack) молча теряют такую пачку → backspace'ы прошли, текст удалён, ничего не набрано.
- **«сдвигает курсор влево»** = буфер пустой (пользователь нажал пробел, потом DoubleShift) → вызывался clipboard-fallback `convertSelectedTextViaClipboard`, который слал `Shift+Option+Left` для выделения слова. В Electron/веб это «move caret word back» без выделения → copy пуст → bail, но курсор уже уехал.

**Fixes (3 файла):**
- `Core/TextReplacer.swift` — `typeStringFast` теперь шлёт **по 1 символу**, keyDown+keyUp оба с `keyboardSetUnicodeString`. Electron-safe, +2.5ms/символ — незаметно.
- `Core/KeyboardMonitor.swift` — добавлена **history `lastCompletedWord`** (keycodes + trailing + timestamp, TTL 5s), сохраняется в word-boundary handler при пробеле/пунктуации. `swapLastWordInBuffer` использует history как fallback когда буфер пуст — после пробела DoubleShift работает ровно как в Caramba.
- `Core/HotkeyManager.swift` — **удалён clipboard-fallback** `convertSelectedTextViaClipboard`. Путь теперь один: buffer → history → no-op с debug-логом. Если пустой буфер + пустая history → тихо ничего (никаких больше скачущих курсоров).

**Тесты:** 51/51 passed. Build: 0 warnings.

### Второй проход (досканальный аудит того же класса багов, 23 апр)
По просьбе Саши пошёл искать родственные баги. Нашёл ещё 4:

- **Bug A — self-capture отменял `pendingSingleShift`.** `hotkeyManager?.markKeyPressed()` в `KeyboardMonitor.handleEvent` вызывался ДО `if isPaused / inCooldown { return }`. Наши собственные retype-события прилетали в event tap, триггерили `markKeyPressed` → cancel pending single-shift. Если юзер жмёт Shift-Shift сразу после автокоррекции — первый Shift scheduled pending, self-capture (300ms cooldown) его отменяет, второй Shift видит `pendingSingleShift == nil` и DoubleShift не срабатывает. Это и есть known bug #1 «Double Shift не всегда с первого раза». **Fix:** перенёс проверки `isPaused / inCooldown` раньше `markKeyPressed`.
- **Bug B — L+R Shift combo оставлял `shiftDownTime`.** После toggle auto-switch через L+R combo последующий shift-release давал `holdDuration ≈ 0` → `wasTap=true` → через 450ms срабатывал призрачный singleShift и переключал раскладку. **Fix:** `shiftDownTime = 0` и `lastShiftUpTime = 0` в combo-ветке.
- **Bug C — `lastCompletedWord` не сохранялся при autoSwitch=OFF.** Word-boundary handler стоял ПОСЛЕ `if !prefsService.isAutoSwitchEnabled { return }`. **Fix:** вынес word-boundary и history-capture ДО autoSwitch-гейта; `processCurrentWord` при OFF не вызывается, но history заполняется, так что DoubleShift работает даже с выключенным автопереключением.
- **Bug D — Cmd+V без симметричных флагов.** `handlePasteNoFormat` ставил `.maskCommand` только на keyDown. Часть Electron-клиентов нестабильно реагирует. **Fix:** `ku?.flags = .maskCommand`.
- **Bug E (bonus) — `anyModifierWithShift` ставился навсегда.** Прошлый Option-клик (не одновременный с Shift) навсегда поднимал флаг, пока не случится shift-цикл-сброс. **Fix:** флаг ставится только если `leftShiftDown || rightShiftDown` В ДАННЫЙ МОМЕНТ, и каждый fresh shift-press (когда никакой shift до этого не держался) сбрасывает `anyKeyBetweenShifts` и `anyModifierWithShift` — чистый старт цикла.

**Тесты после второго прохода:** 51/51 passed, 0 warnings.

## Version 0.2.0 hotfix (2026-04-22, позже вечер)

### Signing — persistent identity
- `./Scripts/setup-signing.sh` создаёт "SashaSwitcher Developer" в login keychain (один раз). Self-signed, 10 лет. Нужен пароль от Mac
- `build.sh dev` использует identity без `-v` (self-signed виден как CSSMERR_TP_NOT_TRUSTED — это нормально, codesign работает)
- Результат: `Authority=SashaSwitcher Developer`, стабильный CDHash → TCC permissions переживают rebuild

### Onboarding UX
- `OnboardingView.swift`: `PermissionsWatcher` polls `AXIsProcessTrusted` + `CGPreflightListenEventAccess` каждую секунду. Кнопка "Далее" активируется когда `hasAll=true`. Auto-close убран — пользователь сам подтверждает
- First-run: `UserDefaults "tech.sasha.switcher.onboardingSeen"` — окно показывается один раз даже если permissions уже на месте, чтобы пользователь увидел подтверждение

### UI
- Удалён переключатель Dark/Light/Auto — темы не работали, оставлен auto (`NSApp.appearance = nil`)
- Все 4 stat-карточки теперь toggle-кнопки (как в Caramba):
  - Автопереключение → `isAutoSwitchEnabled`
  - Опечатки → `isTypoFixEnabled` (UI-заготовка)
  - Single Shift → `isSingleShiftEnabled` (управляет Single Shift + CapsLock triggers)
  - Option → `isDoubleShiftEnabled` (управляет Double Shift / Option конвертацией слова)
- Menu bar icon: `isTemplate=true` + NSColor.black — macOS автоматически красит monochrome под цвет menubar (было цветное)

### Known — не реализовано
- `isTypoFixEnabled` — чисто UI тумблер, логика не отвязана от главной `isAutoSwitchEnabled`. TODO: отдельная ветка для dictionary-only typo correction
- Windows-версия — отложена на 6-12 месяцев (Rust + tauri + global-hotkey)
- App Store (Stage 3) — требует переход с CGEventTap на IMKit

### DMG для distribution (Scripts/make-dmg.sh)
- Universal binary (arm64 + x86_64) через `swift build --triple ...` x2 + `lipo -create`
- Подписана persistent identity + Hardened Runtime
- В DMG: .app + symlink на Applications + `ПРОЧТИ_МЕНЯ.txt` с инструкцией для друга
- Stage 1 caveat: первый запуск на чужом Mac требует "right-click → Open → Open" для обхода Gatekeeper (прописано в README). Stage 2 (notarization) уберёт этот шаг
