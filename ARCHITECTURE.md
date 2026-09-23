# Qwerty Switcher — архитектура

Нативное menu-bar приложение для macOS 13+, которое локально определяет неверную
раскладку набираемого слова, переключает источник ввода и исправляет текст.
Публичное имя и bundle ID: `Qwerty Switcher`, `tech.sasha.qwertyswitch`.
Внутреннее имя SwiftPM-target/executable переименовано из `SashaSwitcher` в
`QwertySwitcher` 03.08.2026; signing identity осталась "SashaSwitcher Developer"
(смена сбросит TCC-разрешения).

## Стек

| Компонент | Реализация |
|---|---|
| Язык и сборка | Swift tools 5.9, SwiftPM, AppKit + SwiftUI |
| Перехват ввода | `CGEventTap` с Accessibility и Input Monitoring |
| Раскладки | Carbon TIS + `UCKeyTranslate` |
| Определение языка | Bloom filter, `NSSpellChecker`, n-gram и частотный/context score |
| Хранение | `UserDefaults`, локальный Bloom-кэш и локальный debug log |
| Дистрибуция | self-signed beta, Developer ID DMG, отдельная App Store sandbox-ветка |

Since 0.10.0 the app is free and has no licensing or device-identity traffic.
Opt-in updates fetch an Ed25519-signed manifest, then verify archive size,
SHA-256, bundle signature, signing identity, and build before installation.
Typing analysis remains local. Logs contain decision metadata; the verbose
log (off by default) also records key codes so a wrong correction can be
traced, and «Собрать отчёт» strips those lines before sharing. Diagnostic
files are owner-only (0600 in a 0700 folder).

## Основные компоненты

```text
Sources/QwertySwitcher/
├── AppIdentity.swift               публичные и legacy-идентификаторы
├── AppDelegate.swift               создание сервисов, onboarding, health polling
├── Core/
│   ├── KeyboardMonitor.swift       event tap, буфер, коррекция, context invalidation
│   ├── HotkeyManager.swift         Shift-комбинации, Caps Lock, plain-text paste
│   ├── InputBuffer.swift           keycode/flags и границы слова
│   ├── InputSourceManager.swift    TIS, layout verification, UCKeyTranslate
│   ├── LanguageDetector.swift      scoring и решение о переключении
│   ├── TextReplacer.swift          проверка layout, backspace/retype, cancellation
│   ├── SecureInputDetector.swift   Secure Event Input + AXSecureTextField
│   ├── UndoManager.swift           одна отменяемая транзакция коррекции
│   └── *Tracker/*Resolver.swift    чистые state machines для горячих клавиш
├── Dictionary/
│   ├── BloomFilter.swift           SSBF v2 + fingerprint и строгая валидация кэша
│   └── WordDictionary.swift        словари EN/RU + системный spell checker
├── Services/                       настройки, профили приложений, snippets,
│                                  timed pause, backup, лицензия и privacy
├── UI/                             status bar, onboarding и окна настроек
└── Tests/TestRunner.swift          автономный test runner без XCTest
```

Legacy-настройки `tech.sasha.switcher.*` мигрируются один раз в новый namespace.
Новые данные находятся в `~/Library/Application Support/QwertySwitcher`, журнал —
в `~/Library/Logs/QwertySwitcher/debug.log`.

## Поток обработки

```text
physical CGEvent
  ├─ synthetic/replayed marker → пропустить повторный анализ
  ├─ flagsChanged → HotkeyManager
  └─ keyDown
       ├─ secure field → очистить контекст и ничего не буферизовать
       ├─ Cmd/Ctrl/Option → инвалидировать word/Undo-контекст
       ├─ letter → добавить keycode + Shift/Caps flags
       ├─ Space/актуальная пунктуация/цифра → завершить слово
       └─ Enter/Tab/Esc → очистить без автозамены
```

Пунктуация и символ после слова вычисляются через активный TIS layout. Жёсткая
US-карта используется только как fallback, поэтому Russian/RussianWin и другие
установленные раскладки не получают американский символ по ошибке.

## Определение языка

Для каждой из двух выбранных раскладок физические нажатия конвертируются с
сохранением регистра. Кандидат получает словарный, spell-check, n-gram,
частотный и контекстный score. URL, email, hex-подобные значения, uppercase
аббревиатуры, mixed-script и неоднозначные результаты не переключаются.

Автокоррекция запускается для слов от трёх букв и только на безопасной границе.
Enter/Tab/Esc не запускают замену, потому что в мессенджере поле уже могло быть
отправлено или сменено.

## Транзакция замены

1. Создаётся независимый cancellation token.
2. Целевая раскладка выбирается и проверяется до удаления текста.
3. Удаляется слово вместе с уже напечатанным trailing-символом.
4. Исправленный текст и точный trailing-символ вводятся Unicode-событиями по
   одному символу — это совместимо с Electron/web-полями.
5. Только успешная транзакция записывает Undo и статистику.

Пока идёт замена, физические клавиатурные события временно ставятся в очередь и
затем переигрываются с отдельным marker. Клик или активация другого приложения
отменяет оставшуюся замену и инвалидирует старый буфер/Undo. Уже отправленные
низкоуровневые события нельзя сделать атомарными средствами `CGEvent` — этот
краевой сценарий дополнительно проверяется вручную в реальных приложениях.

## Горячие клавиши

| Комбинация | Действие |
|---|---|
| Single Shift | Сменить выбранную раскладку |
| Double Shift (окно 600 мс) | Конвертировать текущее/последнее слово; повторно — Undo |
| Left + Right Shift | Toggle on final release; typing or another modifier cancels the gesture |
| Caps Lock | Сменить раскладку, если функция включена |
| Cmd + Option + Shift + V | Вставить plain text с безопасным восстановлением clipboard |
| Cmd + Option + Z | Отменить последнюю коррекцию |

Undo не имеет таймера, но инвалидируется следующим физическим редактированием,
командным сочетанием, кликом, сменой приложения или иным новым контекстом.

## Secure Input и privacy

`IsSecureEventInputEnabled()` is checked synchronously before buffering.
Supplementary AX role/subrole detection is refreshed asynchronously with a
500 ms cache to keep IPC out of the event-tap callback. AX-only secure fields
therefore have a detection delay; this is not a guarantee about every custom
password widget. Missing system permissions prevent the event tap from starting.

`PrivacyInfo.xcprivacy` declares UserDefaults and file-timestamp access, with
no collected data or tracking. Release scripts scan for credentials, require
a signing identity, and verify the update-feed signature before publication.

## Сборка и проверка

```bash
./Scripts/test.sh
./Scripts/build.sh
./Scripts/make-dmg.sh
```

`make-dmg.sh` создаёт universal `arm64+x86_64` приложение и UDZO DMG. На macOS 26+
используется `diskutil image create from`; `hdiutil create` оставлен fallback для
старых систем. Локальная beta подписана persistent self-signed identity и требует
ручного Gatekeeper override на другом Mac.

Developer ID-кандидат собирается командой `./Scripts/make-dmg.sh developerid`:
приложение и финальный DMG подписываются `Developer ID Application` с secure
timestamp, после чего именно DMG отправляется через `./Scripts/notarize.sh dmg` и
получает stapled ticket. App Store workflow описан в `docs/SIGNING.md` и отдельно
проверяет profile, bundle ID, sandbox entitlement и Apple Distribution signature.

На macOS 27 системное создание синтетического `CGEvent` может зависнуть внутри
SkyLight. Test runner пропускает только зависящие от него GUI/integration checks;
чистые state-machine, storage и release-contract проверки продолжают выполняться.
