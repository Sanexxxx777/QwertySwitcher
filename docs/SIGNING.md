# Code Signing & Distribution Roadmap

Три стадии жизни приложения, от локальной разработки до публикации в Mac App Store. Каждая следующая добавляется к предыдущей.

---

## Stage 1 — Local development (бесплатно)

**Сейчас.** Приложение запускается только на твоём Mac. TCC-разрешения (Accessibility, Input Monitoring) сохраняются между rebuild'ами благодаря persistent self-signed identity.

### Первоначальная настройка

```bash
cd ~/Projects/SashaSwitcher
./Scripts/setup-signing.sh    # создаёт cert "SashaSwitcher Developer" в Keychain (один раз)
./Scripts/build.sh            # dev mode по умолчанию
open build/SashaSwitcher.app
```

При первом запуске macOS попросит разрешения (Onboarding) — дай их через System Settings. Все последующие `./Scripts/build.sh` уже не будут сбрасывать permissions.

### Что можно / нельзя

- ✅ Запускать на своём Mac сколько угодно
- ✅ TCC permissions переживают rebuild
- ❌ Отправить другому человеку — Gatekeeper заблокирует (нет Apple-подписи)
- ❌ Загрузить в App Store

---

## Stage 2 — Developer ID distribution ($99/год)

Apple Developer Program. Можно подписывать Developer ID Application certificate и нотаризовать → DMG / zip можно отправить любому пользователю Mac без блокировок Gatekeeper.

### Настройка (один раз)

1. **Купить Apple Developer Program** — https://developer.apple.com/programs/ (~ $99/год).
2. **Создать Developer ID Application certificate**:
   - Xcode → Settings → Accounts → Add Apple ID → Manage Certificates → `+` → **Developer ID Application**
   - Либо через https://developer.apple.com/account/resources/certificates/list
3. **Сохранить app-specific password** для notarization:
   ```bash
   xcrun notarytool store-credentials notarize-sasha \
     --apple-id "твой@email.com" \
     --team-id  "XXXXXXXXXX" \
     --password "xxxx-xxxx-xxxx-xxxx"   # https://appleid.apple.com → app-specific passwords
   ```

### Сборка и распространение

```bash
./Scripts/build.sh developerid    # подпись Developer ID
./Scripts/notarize.sh             # submit + staple (2–10 мин)
```

Получишь `build/SashaSwitcher.app` с notarization ticket'ом. Упакуй в DMG:

```bash
hdiutil create -volname "SashaSwitcher" \
    -srcfolder build/SashaSwitcher.app \
    -ov -format UDZO SashaSwitcher-0.2.0.dmg
```

Этот DMG можно:
- выложить на свой сайт
- отправить друзьям по Telegram
- подключить к Homebrew Cask (`brew install --cask sasha-switcher`)

### Что можно / нельзя

- ✅ Распространять кому угодно, без App Store
- ✅ Sparkle auto-updates (обновления без ручного скачивания)
- ✅ Полный доступ к CGEventTap / Accessibility
- ❌ В App Store всё ещё нельзя — нужен Stage 3

---

## Stage 3 — Mac App Store ($99/год, те же деньги)

Та же подписка на Developer Program. Добавляется:
1. Другой certificate: **Apple Distribution**
2. **Provisioning Profile** с entitlements
3. **App Sandbox** — обязательно. Это самая сложная часть для SashaSwitcher.

### ⚠ Архитектурный нюанс: CGEventTap + App Sandbox несовместимы

Внутри App Sandbox `CGEventTapCreate(.cgSessionEventTap, …)` **не работает** — Apple явно запрещает перехват событий sandboxed apps.

Альтернативы:

| Путь | Суть | Сложность |
|---|---|---|
| **Input Method Kit (IMKit)** | Зарегистрировать SashaSwitcher как метод ввода (как китайские/японские IME). Apple одобряет IME в App Store | средняя — переписать перехват клавиш через IMKit |
| **Accessibility API only (AX…)** | Вместо event tap использовать `AXUIElementPerformAction` для чтения текущего текста в поле ввода и `AXUIElementSetAttributeValue` для замены. Работает в sandbox если есть `com.apple.security.temporary-exception.accessibility-api` entitlement | высокая — reviewers иногда отклоняют такой подход |
| **Non-App Store only** | Остаться на Stage 2 (Developer ID + Notarize + DMG). Так делает Caramba до сих пор на части версий | низкая — уже сделано |

**Моя рекомендация:** начать со Stage 2 (DMG + Sparkle) — это даст доход и userbase. Параллельно планировать переписывание на IMKit для App Store. Это большой проект (~1–2 недели).

### Подготовка App Store-сборки (когда будешь готов)

1. **Apple Distribution certificate** (App Store Connect → Certificates)
2. **App ID** с bundle ID `tech.sasha.switcher` (уже тот же)
3. **Provisioning Profile** типа "Mac App Store"
4. Переписать перехват клавиш на IMKit (или Accessibility-only)
5. Создать `Resources/SashaSwitcher.appstore.entitlements`:
   ```xml
   <key>com.apple.security.app-sandbox</key><true/>
   <key>com.apple.security.device.audio-input</key><false/>
   <!-- IMKit-specific entitlements -->
   <key>com.apple.input-methods</key><true/>
   ```
6. `./Scripts/build.sh appstore`
7. Загрузить через Transporter.app или `xcrun altool`
8. Заполнить метаданные на App Store Connect
9. Review Apple (2–7 дней)

### Что можно

- ✅ $4.99/месяц / $19.99 lifetime подписки (один из планов из памяти)
- ✅ Автообновления через App Store
- ✅ Доверие пользователей к "App Store app"

---

## Справочник по командам

| Команда | Режим | Результат |
|---|---|---|
| `./Scripts/setup-signing.sh` | — | создаёт self-signed identity (один раз) |
| `./Scripts/build.sh` или `build.sh dev` | Stage 1 | локальная сборка, TCC-стабильная |
| `./Scripts/build.sh developerid` | Stage 2 | Developer ID-подписанная .app |
| `./Scripts/notarize.sh` | Stage 2 | нотаризация + staple |
| `./Scripts/build.sh appstore` | Stage 3 | App Store-пригодная .app (требует переписи) |

---

## Как проверить текущее состояние подписи

```bash
codesign -dv --verbose=4 build/SashaSwitcher.app 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Timestamp'
```

Выведет что-то вроде:

```
Identifier=tech.sasha.switcher
Authority=SashaSwitcher Developer               ← stage 1
# или
Authority=Developer ID Application: Your Name   ← stage 2 (notarized)
# или
Authority=Apple Distribution: Your Name         ← stage 3 (App Store)
```
