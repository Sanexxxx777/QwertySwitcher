# Qwerty Switcher — macOS Keyboard Layout Auto-Switcher

Нативное macOS приложение для автоматического переключения раскладки клавиатуры (аналог Caramba Switcher).

## Tech Stack
- Swift tools 5.9 (локально Swift 6.4), SwiftUI + AppKit, SPM (без Xcode)
- CGEventTap (перехват клавиш), TIS API (раскладки), UCKeyTranslate (маппинг)
- BloomFilter + NSSpellChecker (словарь 714K слов; Bloom ~1MB + префикс-индекс мгновенной коррекции ~11MB RAM, строится асинхронно)

## Structure
```
Sources/QwertySwitcher/
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
./Scripts/test.sh               # Swift-сьют via --test + контракты Tests/ReleaseScripts/*.sh
./Scripts/build.sh              # release .app текущей архитектуры
./Scripts/install.sh            # обновить /Applications БЕЗ сброса TCC (см. секцию ниже)
./Scripts/make-dmg.sh           # universal (arm64+x86_64) .app + DMG для distribution
```

## 🔴 Git-состояние: НИКОГДА не трогать (инцидент 05.08.2026)

**Запрещены полностью, и агентам в том числе:** `git stash`, `git reset`, `git checkout -- .`, `git restore`, `git clean`. Работа этого проекта копится большими незакоммиченными кусками, и одна такая команда сносит её молча.

Что случилось 05.08: агент выполнил `git stash`, чтобы «привести дерево в порядок». Из рабочей папки исчезли **3399 строк в 29 файлах** (вся работа 0.4.3–0.4.9, включая 1438 строк тестов). Дальше параллельные агенты продолжили писать код поверх версии двухдневной давности — то есть чинили уже починенное и переделывали UI, у которого не было ни тем, ни вкладок. Обнаружилось только по косвенному признаку: пропали механизмы, которые точно работали в установленной сборке.

**Правила, снимающие этот класс аварий:**
1. **Коммит ПЕРЕД делегированием.** Прежде чем запускать агента, который будет править файлы, — локальный коммит. Точка возврата важнее красоты истории.
2. **Дерево «грязное» — это норма здесь, а не беспорядок.** Не «прибираться» в нём.
3. **Разные агенты — непересекающиеся файлы**, список файлов выдавать явно в промпте. Тесты живут в одном `TestRunner.swift` — значит правит его РОВНО ОДИН агент за раз.
4. Заметил, что из дерева пропал код, который точно работал → **`git stash list` и `git fsck --lost-found` ПЕРЕД любыми правками**. Восстановление дешёвое, переписывание заново — нет.

## 🔴 Обновление установленной копии — ТОЛЬКО `./Scripts/install.sh` (инвариант, 04.08.2026)

Ручное копирование в `/Applications` сбрасывало Accessibility/Input Monitoring. Две независимые причины, обе лечатся одним `rsync -a --delete` внутри `install.sh`:
1. **`rm -rf "/Applications/Qwerty Switcher.app"` перед копированием = деинсталляция для macOS.** Исчезновение каталога → tccd удаляет строку в TCC.db (ключ = bundle id + csreq, НЕ CDHash). Доказано A/B на этом Маке: пересозданный каталог → `perms accessibility=false`; тот же каталог обновлён на месте с ДРУГИМ CDHash → `perms accessibility=true`. ⇒ каталог-назначение обязан пережить обновление.
2. **`ditto src dst` поверх существующего бандла МЕРЖИТ, не удаляет.** Один файл-сирота от прошлого релиза внутри `Contents/` ломает печать ресурсов → приложение перестаёт удовлетворять своему Designated Requirement → tccd не матчит сохранённый csreq → разрешения спрашиваются заново. ⇒ копия обязана подчищать (`--delete`).
3. **Сохранённый csreq НАЗЫВАЕТ signing identity** (`identifier "tech.sasha.qwertyswitch" and certificate leaf = H"a80cd00f…"` — это leaf-хэш сертификата «SashaSwitcher Developer» из login-keychain). Сборка с ДРУГОЙ identity сбрасывает гранты, даже если каталог и его inode целы. Главный реальный путь сюда: `build.sh` при отсутствии сертификата в связке молча падает в ad-hoc (`build.sh:117-124`, DR становится cdhash-based и меняется каждую пересборку). ⚠️`codesign --verify` такое НЕ ловит в принципе — он проверяет бандл против DR, вшитого в его же подпись, поэтому ad-hoc сборка честно «satisfies its Designated Requirement». ⇒ identity источника сверяется с установленной копией отдельным гейтом ДО синка (`install.sh` шаг [2/5], отказ = exit 7, ничего не тронуто). Осознанная смена identity — `--allow-identity-change`, и тогда скрипт прямо пишет, что разрешения будут запрошены заново.

```bash
./Scripts/build.sh && ./Scripts/install.sh     # единственный правильный путь
```
`install.sh` идемпотентен: гасит только процесс, запущенный из целевого бандла (ДО подмены файлов — иначе новый код не подхватится), обновляет содержимое на месте, и **блокирующим гейтом** гоняет `codesign --verify --deep --strict` по установленной копии. Провал гейта = разрешения будут потеряны, установку не считать успешной. В выводе печатается inode до/после — совпал = гранты целы.

**Граница покрытия (не расширять заявление):** `install.sh` — путь разработчика на ЭТОЙ машине. Пользовательское обновление из DMG (перетаскивание с «Заменить») удаляет каталог бандла руками Finder'а = причина №1 в чистом виде, гранты слетают, и install.sh тут ни при чём. Смягчение — не установщик, а онбординг: окно «Добро пожаловать» + пункт меню «Настройка разрешений…» (`OnboardingWindowController`), плюс п.4 в `ПРОЧТИ_МЕНЯ.txt` внутри DMG. Полное решение = in-app updater, его НЕТ. Также вся сохранность висит на leaf-хэше одного self-signed сертификата в login-keychain: потеря связки или переход на Developer ID (Stage 2) = гарантированный сброс у всех, у кого стоит текущая сборка.

**Don't:** `ditto`/`cp -R`/`rm -rf` по `/Applications/Qwerty Switcher.app` руками; гоняться за стабильным CDHash (csreq содержит `identifier` + `certificate leaf`, CDHash в нём нет — но identity есть, см. причину №3, поэтому менять её нельзя). Контракт установщика — `Tests/ReleaseScripts/install_contract.sh`, гоняется из `test.sh`.

## Spotlight — исключение снято (08.08.2026)

Автокоррекция была отключена в `com.apple.Spotlight` флагом `isSpotlight`. Записанной причины у исключения не было (расследовано 04.08 — история git доходит только до squashed-коммита), держалось из осторожности к live-поиску. Снято по отчёту владельца: «sw» показывало «ыц» и так и оставалось. Именно там неверная раскладка бесполезнее всего — запрос просто ничего не находит. Вместе с флагом убран `NSWorkspace.frontmostApplication` из горячего пути: он вызывался на КАЖДОМ нажатии только ради этой проверки. Если Spotlight когда-нибудь начнёт конфликтовать с backspace+перепечаткой — это исключения по приложению (`ExceptionsService`), а не хардкод.

## 🟢 Терминальный класс артефактов РАЗГАДАН (09.08.2026, v0.6.9 — байтовый замер)

Финальная причина «копящихся точек» (`...../exit`): **наша же Cmd+C-проба выделения**, которую Double Shift стрелял ПЕРВОЙ на каждый жест. В kitty-protocol терминалах (Claude Code включает `CSI >1u`) Ghostty доставляет Cmd+C прямо во ввод приложения как `CSI 99;9u`/`CSI 1089;9u` (лат./кир. «c», mod 9=Cmd) — парсер Клода спотыкается и съедает соседний backspace. Пойман бит-в-бит байтовым логгером (`/tmp/qsw_byte_probe.py` → `/tmp/qsw_bytes.log`, 2 сессии: legacy чисто, kitty — CSI перед каждой серией). Сами серии замен чистые в обоих режимах.
**Фиксы (все три в 0.6.9):**
1. Приоритет DS: AX selection → **run/buffer** → clipboard probe → caret word → undo. Cmd+C не шлётся, когда есть свежий набор. Конфликт «выделение vs run» исключён — клики/навигация чистят run.
2. `TextReplacer` AX-проба перед заменой: поле «читаемо» только если `len>=need && caret>=need` (Ghostty отвечает ПУСТЫМ AXValue формально успешно, а иногда всем скроллбеком с caret=0 — nil-проверки мало); нечитаемо → пейсинг 2.5мс→15мс (`carefulKeystrokeDelay`).
3. Overlay-доставка: Spotlight-класс полей берёт фокус НЕ становясь frontmost → синтетика с session tap летит в чужое окно (терминал получал «прив», «с»). `AXTextSelectionService.overlayTargetPid(element)` → замена, Cmd+C-проба и Cmd+V уходят через `CGEvent.postToPid(focusedPid)`. Подтверждено владельцем: Spotlight работает.
**Don't:** не возвращать clipboard-пробу раньше run-конверсии; не «оптимизировать» careful-пейсинг; не ослаблять критерий AX-читаемости до nil-проверки.

## 🔴 В Ghostty сверка с экраном НЕДОСТУПНА — `ax=none` (08.08.2026, доказано логом)

Строка `run check: model=N ax=none → model kept` в живом логе (19:43:38, 19:46:45) значит: **терминал не отдаёт ни значения поля, ни позиции курсора**, поэтому механизм «экран решает сколько стирать» там не работает вообще и программа опирается на модель. В той же паре строк `model=1` при двух реально набранных клавишах — модель отставала.

Это объясняет, почему весь класс артефактов (`пgmail`, `йq1`, `ЙQ1`, `./exit`, `Смотри оги,снова`) живёт именно в терминале, а не в обычных полях: там сверка ловит расхождение и лечит, здесь — нет.

**Следствие для следующей работы:** в приложениях без AX единственная защита — не терять клавиши в самой модели. Известные утечки закрыты (backspace, secure input, простой, границы, смена раскладки), но остаётся минимум одна: чистый набор `й1`/`./exit` в тестах конвертируется верно, а в поле модель короче экрана. **Не угадывать причину** — сначала воспроизвести в Ghostty с включённым `Подробный лог` и посмотреть, на какой клавише `run` перестаёт расти.
**Don't** пытаться прочитать текст терминала синтетическим Cmd+C — запрет на синтетические каретко-двигающие клавиши стоит с v0.2.0 (см. историю ниже), он ровно об этом.

## 🔴 Модель ввода дрейфует — экран решает СКОЛЬКО, клавиши ЧТО (08.08.2026)

Мы ведём модель напечатанного (`buffer`, `runKeystrokes`), но текст живёт на экране. Любое расхождение немедленно превращается в неверное число backspace, и пользователь видит обрубок или лишний символ. Три полевых артефакта одного класса за одну сессию: `пgmail` (модель 5 клавиш, экран 6 символов), `йq1` (прогон на клавишу короче; лог `keys=2 net=0` — сама замена отработала штатно, врал СЧЁТ), `Смотри оги,снова`.

- **Перед заменой Double Shift сверяет прогон с реальным текстом под курсором** (`AXTextSelectionService.valueAndCaret` + `CaretWordExtractor.wordBeforeCaret`). Разошлись → мерим экран, в лог идёт `run resynced from screen: model=N screen=M`. AX молчит (часть терминалов/Electron) → работаем по модели.
- **Конвертируем по keycodes, пока модель согласна с экраном.** `LayoutTextConverter` (текст→текст) — только на ресинке: у него нет обратного отображения для `/`, `-`, `=` и он превратил бы `/exit` в `.exit`. Поймано тестом на первой, слишком широкой версии перехвата.
- **`runKeystrokes` обязан сбрасываться везде, где экран меняется мимо нас:** пробел/Enter/Tab, навигация, backspace, secure input, отбрасывание по простою, смена раскладки, `invalidateEditingContext`. Пропустил одно место — получил дрейф. Это уже случалось.
- **Don't:** судить `net=` по сырым `bs=`/`pay=` — подавленный триггер даёт законную разницу в 1 символ (мониторинг на этом дал три ложные тревоги подряд). `net` считает чистое изменение длины и обязан быть 0.

## 🔴 macOS шлёт уведомление о смене раскладки ДВАЖДЫ (08.08.2026)

`kTISNotifySelectedKeyboardInputSourceChanged` приходит парами через 1–3 мс (в `debug.log`: `07:36:24.072 (self)` + `07:36:24.074` без метки). `pendingSelfSwitchID` одноразовый, поэтому совпадало только первое, а второе шло как ВНЕШНЕЕ переключение — то есть «пользователь ушёл, забудь контекст» через 2 мс после нашей же коррекции. Стирало буфер, историю и `instantCorrectionGate`; отсюда «Double Shift сразу после коррекции отвечает no buffer/history» и повторная коррекция уже исправленного слова.
Лечится `InputSourceManager.classifyChange`: уведомление о **уже активной** раскладке = `.duplicate`, до `KeyboardMonitor` не доходит. **Don't** возвращать одноразовый `pendingSelfSwitchID` как единственный признак «своего» переключения.

## 🔴 Замена текста атомарна после первого backspace

Отмена принимается только ДО первого разрушающего действия. Раньше `sendBackspaces`/`typeStringFast` проверяли токен внутри цикла — обрыв на середине оставлял текст стёртым и ненапечатанным, то есть **терял символы навсегда**. Всё медленное (переключение раскладки и его верификация) происходит до этой точки, так что полезное окно отмены не пострадало. Инвариант держит `ReplacementAtomicityGuardTests` — он читает исходник через `#filePath`, потому что гонять живой `TextReplacer` в тестах = постить CGEvent в реальный ввод владельца (ровно та авария 05.08).

## Контраст — числом, не на глаз (08.08.2026)

`StatusInk` полгода существовал, но тема брала сырые `.systemGreen/.systemOrange/.systemRed` — это и был нечитаемый зелёный заголовок. Значения считаются против **худшей из двух поверхностей** каждой темы (окно `#ECECEC`/`#1E1E1E`, карточка `#FFFFFF`/`#323232`): прежний набор проходил на карточке и падал на окне. Гейт — `StatusInkContrastTests` (формула WCAG в `Contrast.ratio`), порог 4.5:1.
⚠️Поверхности заморожены константами сознательно: `NSColor.windowBackgroundColor` резолвится по-разному в зависимости от того, есть ли в процессе NSApplication, и тест начинал зависеть от способа запуска, а не от цветов.

## Канон имён и путей (стандарт 03.08.2026 — НЕ плодить копии)
- **Установленная копия ОДНА: `/Applications/Qwerty Switcher.app`** — обновлять ТОЛЬКО через `./Scripts/install.sh` (см. секцию выше), НЕ запускать из build/.
- `build` — симлинк на `build.noindex/` (Spotlight не индексирует сборки; лечит расплод «Qwerty Switcher.previous-*» в поиске). Не переименовывать обратно.
- Previous-копия сборки/DMG хранится РОВНО одна: `build/previous/` (скрипты сами ротируют). Таймстампованных `.previous-*` больше не существует — их появление = регресс скриптов.
- Публичное имя `Qwerty Switcher`, bundle `tech.sasha.qwertyswitch` (AppIdentity.swift — единственный источник). Внутренний модуль/binary переименован из `SashaSwitcher` в `QwertySwitcher` 03.08.2026; signing identity осталась "SashaSwitcher Developer" — НЕ переименовывать: смена identity сбросит TCC-разрешения.
- Скрипты — bash 3.2 (системный): пустые массивы раскрывать ТОЛЬКО как `${ARR[@]+"${ARR[@]}"}`, иначе `set -u` роняет сборку после стадии компиляции (пойман 03.08: codesign не выполнялся).

Debug logs: `~/Library/Logs/QwertySwitcher/debug.log` (rotation at 1MB).
Menu → "Показать логи" / "Открыть папку логов".

## Key Features
- 4-level scoring: Dictionary + SpellCheck + N-gram + WordFrequency + Context
- Hotkeys: Single Shift, Double Shift, L+R Shift toggle (✅/❌ indicator), CapsLock, Cmd+Shift+V, **Cmd+Option+Z** undo
- Minimum word length 3 (avoids false positives on 2-letter particles)
- Liquid Glass UI (NFA design system, dark only — auto appearance)
- Per-app layout memory, exceptions (word + app + auto-learn with per-entry delete), Ёфикатор
- Onboarding window — живёт всю сессию в `OnboardingWindowController` (сильная ссылка из AppDelegate). `.floating` + `[.canJoinAllSpaces, .stationary]` + `orderFrontRegardless()` на каждой активации + `.regular` activation policy на время онбординга: без этого окно уходило ПОД System Settings и было недостижимо (app = accessory, нет Dock/Cmd+Tab). Возврат из меню статус-бара «Настройка разрешений…». Опрос TCC — таймер в `.common` mode, не глохнет на onDisappear. Кнопки «Проверить снова» и «Перезапустить приложение» (последняя только в шаге `.stalled`). Логика шагов — `Services/OnboardingState.swift` (чистая, покрыта тестами)
- ⚠️**Перезапуск после выдачи разрешения НЕ нужен** и в UI так не писать: гранты подхватываются в том же процессе (`AppDelegate.startHealthPolling` → `KeyboardMonitor.refreshHealth`, доказано в debug.log — `perms accessibility=false` → `[KM] event tap started` через 30с, тот же PID). Алерт macOS «Завершить и открыть снова» → «Позже». Restart предлагается ТОЛЬКО когда оба гранта есть, а перехват не поднялся дольше `restartGraceSeconds`
- ⚠️Не звать `request*()` и `open*Settings()` подряд — это поднимает ДВЕ чужие поверхности поверх нашего окна. Порядок: `PermissionsService.request*ThenSettings()` (промпт → через 0.7с System Settings только если не помогло → колбэк возвращает наше окно вперёд). Второй путь того же кода — `MainViewModel.openPermissionRepair()`
- ⚠️Input Monitoring — производная от Accessibility: отдельной строки `kTCCServiceListenEvent` для `tech.sasha.qwertyswitch` в TCC.db нет вообще, `CGPreflightListenEventAccess()` возвращает true за счёт Accessibility. Поэтому сначала просим Accessibility, и оба флага всегда меняются синхронно
- Secure input detection, Spotlight skip, 300ms self-capture cooldown
- Context reset on layout change (manual or by bot)
- Privacy: 100% local, 0 telemetry, audit on launch

## Signing & Distribution (see docs/SIGNING.md)
- **Stage 1 (current):** persistent self-signed identity "SashaSwitcher Developer" in login keychain → stable CDHash → TCC permissions survive rebuilds. Run once: `./Scripts/setup-signing.sh` (asks for login password once to unlock keychain + set partition list). Free.
- **Stage 2:** Developer ID + notarization для публичного DMG. Финальный путь: `make-dmg.sh developerid` → `notarize.sh dmg`; и `.app`, и DMG получают timestamped Developer ID signature.
- **Stage 3:** отдельная App Store sandbox-сборка и `.pkg` pipeline подготовлены. Нужны реальные Apple certificate/profile, чистый Mac test и App Review; статический реверс sandboxed Caramba/Lang не заменяет этот live-test.

## Лицензирование (v0.4.0, 03.08.2026)
- Модель: подписка по ключам `QSW-XXXX-XXXX-XXXX` + триал 14 дней, привязка к hardware UUID (IOPlatformUUID) — переустановка не сбрасывает срок.
- Сервер: S1 `/root/qsw-license/` (Flask, pm2 `qsw-license`, bind 127.0.0.1:8377), наружу `https://backend-test.45-82-95-142.nip.io:8443/qsw/v1/*` (nginx-location в `developer-contact-api`, `/qsw/admin` снаружи = 404). Админ — ТОЛЬКО с S1: `source /root/qsw-license/.env; curl -H "X-Admin-Token: $QSW_ADMIN_TOKEN" http://127.0.0.1:8377/admin/…` (шпаргалка `deploy-notes.md` там же).
- Крипта: ответы сервера подписаны Ed25519; приватный ключ ТОЛЬКО на S1 (`server_ed25519.pem`, chmod 600, Мак его не видел); публичный вшит в `Services/LicenseService.swift`. Канонизация payload = python `json.dumps(sort_keys=True,separators=(",",":"))` — Swift собирает строку руками, НЕ JSONEncoder.
- Клиент: состояние в Keychain (`tech.sasha.qwertyswitch.license`, переживает переустановку); check-in при старте + каждые 12ч; офлайн-грейс 14 дней; первый запуск офлайн → provisional-триал до первого контакта с сервером; откат часов ловится maxSeen. Enforcement: `canAutoCorrect` и Double Shift гейтятся `LicenseService.shared.isEntitled`; Single Shift и Undo сознательно НЕ гейтятся.
- Приватность честно: ввод локально, на сервер уходит ТОЛЬКО hwid + версия (формулировка в UI/About обновлена; «0 телеметрии» больше не заявляем).
- Граница защиты: обходы переустановкой/чисткой файлов/откатом часов закрыты; патч бинарника реверсом — НЕ закрыт (нативное приложение без обфускации, честный предел).

## Current v0.6.3 (2026-08-08) — 374 passed, 0 failed, 1 skipped

Символы и прогоны: клавиша `, . ; [ ] ' \`` больше не закрывает слово в момент нажатия (39.6% русских слов ≥3 букв содержат хотя бы одну из `б ю х ж ё э ъ` — измерено по словарю), решение отложено до пробела; детектор разбирает набранное на ведущие знаки + буквенное ядро + хвостовые знаки, оценивает словарём только ядро, **>1 ядра → кандидат отвергается** (это и защищает терминал: `model/path`, `--flag=value`, `./script.sh`).
Ложные срабатывания: `contextBias` 5 при `collisionGap` 10 (было 15 — подсказка «до этого был русский» в одиночку изготавливала победителя) + `incumbentGap` 25 — перебить текст, который уже читается как настоящее слово, можно только с большим отрывом. Мгновенная коррекция не трогает прогоны со спорной клавишей (`runHasAmbiguousKey`): она срабатывает до появления улик и своих защит не имеет.
Double Shift: конвертирует **весь прогон** (`runKeystrokes` — буквы + цифры + символы) клавиша-в-клавишу без словаря, когда в прогоне есть не-буква. Явный жест — не запрос на суждение.

### TODO
- **high** — полевой verify 0.6.10 (установлена 13.08, витрина обновлена): «b»+пробел+Double Shift и одиночная «.» там, где нужен «/», обязаны конвертироваться. Дешёвая AX-проба уже подтверждена — строка `ax probe: no char-count attribute` за 50 минут работы не появилась ни разу, значит поля отдают `kAXNumberOfCharacters` и значение поля больше не копируется.
- **high** — полевой verify 0.6.9: «.учше»→DS×N в сессии Claude Code (точки не копятся) + предложение с однобуквенными союзами в Ghostty («пробел вместо буквы», repro не снят — лог 09.08 20:08:49 `correction len=1` кандидат). После verify выключить «Подробный лог» (включён через defaults 09.08).
- **high** — применить токены `Space`/`Radius` по всему `MainView` (сейчас живут только в новых компонентах, остальной файл на магических 4/6/8/10/11/12/14).
- **medium** — порог автокоррекции 3 буквы → 2 (`KeyboardMonitor`, `>= 3`), только после корпусного прогона с нулём ложных.
- **medium** — корпусные тесты: слова × хвостовая пунктуация RU и EN, граничный `detect` дважды (контекст ru и en), 58 коллизий, ~200 токенов из реальной истории shell; recall числом, не гейтом.
- **medium** — покрыть путь ресинка от AX (нужен фейковый AX-провайдер, сейчас не покрыт вообще).
- **low** — не воспроизведены: `йц— Сп`, `f[?`→`ах,`, `MVS`.
- **low** — DMG на витрине 0.4.1 при текущей 0.6.3; in-app updater; нотаризация (Stage 2).

## Current v0.4.1 (2026-08-03)
- **Мгновенная автокоррекция (как Caramba)**: срабатывает ПО МЕРЕ НАБОРА, не ждёт пробела. `Core/InstantCorrectionAnalyzer.swift` (пороги: minLength 4, candidateFloor 40, margin 30, гейт wordLevel==0 — словарный префикс своего языка всегда блокирует триггер) + `InstantCorrectionGate` (анти-двойная коррекция с boundary-путём). Тумблер «Мгновенная коррекция» (default ON). Калибровка: 0 false positives на ~3.9K частотных слов EN+RU (корпусный тест в сьюте). ⚠️NSSpellChecker.checkSpelling принимает мусор («zzzz») как валидный EN — в скоринге мгновенной коррекции НЕ используется, только свой словарь/префикс-индекс.
- Boundary-коррекция по пробелу/пунктуации осталась как fallback.
- Тесты: `146 passed, 0 failed, 1 GUI-only skipped`.

## Current v0.4.0 (2026-08-03)
- Переименование завершено: продукт «Qwerty Switcher», модуль/binary `QwertySwitcher`, версия `0.4.0 (4)`.
- Лицензионный слой (см. выше). Тесты: `125 passed, 0 failed, 1 GUI-only skipped`.

## Current v0.3.0 audit (2026-08-02)

- Публичное имя `Qwerty Switcher`, bundle ID `tech.sasha.qwertyswitch`, версия `0.3.0 (3)`.
- Исправлены layout-aware trailing symbols, Russian Shift+б/ю, строгая проверка Bloom cache и пустого словаря.
- Secure Input не кэширует `false`; modifier/focus changes инвалидируют старые word/Undo state.
- Асинхронная замена имеет cancellation token и не пишет Undo/статистику после смены контекста.
- Developer ID/App Store prerequisites проверяются до замены существующего `.app`.
- `111 passed, 0 failed, 1 GUI-only skipped`; universal beta и DMG пересобираются через `make-dmg.sh`.

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

## Historical bugs (исправлены в v0.3.0)
1. ~~**Double Shift не всегда срабатывает с первого раза**~~ ✅ 2026-04-23: Bug A — self-capture отменял `pendingSingleShift`. Перенёс `isPaused/inCooldown` гейты ДО `markKeyPressed`.
2. ~~**Лишняя английская буква при автозамене**~~ — заменён временной cooldown на marker собственных событий; физический ввод во время замены ставится в очередь и переигрывается.
3. ~~**Регистр теряется при автокоррекции**~~ — `BufferedKeystroke` хранит Shift/Caps flags, `UCKeyTranslate` получает их при конвертации.
4. ~~**Одновременное удержание обоих Shifts**~~ — вынесено в `ShiftStateTracker`; combo/release edge cases покрыты регрессиями.

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

### Historical notes — состояние на 2026-04-22
- `isTypoFixEnabled` — чисто UI тумблер, логика не отвязана от главной `isAutoSwitchEnabled`. TODO: отдельная ветка для dictionary-only typo correction
- Windows-версия — отложена на 6-12 месяцев (Rust + tauri + global-hotkey)
- App Store (Stage 3) — требует переход с CGEventTap на IMKit

### DMG для distribution (Scripts/make-dmg.sh)
- Universal binary (arm64 + x86_64) через `swift build --triple ...` x2 + `lipo -create`
- Подписана persistent identity + Hardened Runtime
- В DMG: .app + symlink на Applications + `ПРОЧТИ_МЕНЯ.txt` с инструкцией для друга
- Stage 1 caveat: первый запуск на чужом Mac требует "right-click → Open → Open" для обхода Gatekeeper (прописано в README). Stage 2 (notarization) уберёт этот шаг
