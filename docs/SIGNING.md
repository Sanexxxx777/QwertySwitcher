# Qwerty Switcher: подпись и публикация

Актуальные идентификаторы:

- продукт: `Qwerty Switcher`;
- bundle ID: `tech.sasha.qwertyswitch`;
- внутренний Swift executable: `QwertySwitcher` (переименован из `SashaSwitcher` 03.08.2026; это не видно пользователю);
- signing identity: "SashaSwitcher Developer" (не переименовывать — смена сбросит TCC);
- текущая версия: `0.7.0` (`CFBundleVersion = 31`).

## 1. Локальная beta

Один раз создаётся self-signed certificate. Его старое имя намеренно сохранено,
чтобы не ломать уже настроенные Mac разработчиков.

```bash
cd ~/Projects/QwertySwitcher
./Scripts/setup-signing.sh
./Scripts/test.sh
./Scripts/build.sh
open "build/Qwerty Switcher.app"
```

Из-за нового bundle ID macOS один раз попросит Accessibility и Input Monitoring
заново. После выдачи разрешений приложение само повторит запуск event tap —
перезапускать Qwerty Switcher не нужно.

Self-signed сборку нельзя считать публичным релизом: Gatekeeper на чужом Mac
потребует ручного подтверждения.

## 2. Публичный DMG через Developer ID

Нужны оплаченная Apple Developer Program и сертификат `Developer ID Application`.

```bash
DEVELOPER_ID_APP="Developer ID Application: …" \
  ./Scripts/make-dmg.sh developerid

./Scripts/notarize.sh dmg
```

`make-dmg.sh developerid` собирает universal `arm64+x86_64` приложение и не
допускает fallback на локальную или ad-hoc подпись. Secure timestamp и Developer
ID signature получают и `.app`, и финальный UDZO DMG с отдельным signing ID.
`notarize.sh dmg` повторно проверяет подпись образа, отправляет Apple именно этот
распространяемый DMG, затем stapler прикрепляет ticket к этому же файлу. После
notarization нельзя повторно запускать dev-режим сборки над публичным артефактом.

Для notarization заранее сохранить учётные данные в Keychain profile (по
умолчанию `notarize-sasha`):

```bash
xcrun notarytool store-credentials notarize-sasha \
  --apple-id "…" \
  --team-id "…" \
  --password "…"
```

Пароль не хранится в репозитории: его сохраняет Keychain.

Результаты:

- `build/Qwerty Switcher.app`;
- `build/QwertySwitcher-0.3.0.dmg`.

## 3. Mac App Store

⚠️Снято в 0.10.0: приложение бесплатное, сетевых вызовов нет.

App Store-сборка подготовлена как отдельный sandboxed вариант:

- `Resources/QwertySwitcher.appstore.entitlements` включает только App Sandbox;
- сеть и доступ только к выбранным пользователем JSON-файлам запрашиваются;
  Apple Events, JIT и debug-entitlements не запрашиваются;
- `PrivacyInfo.xcprivacy` объявляет отсутствие tracking, использование
  UserDefaults для функций приложения и передачу device ID для лицензирования;
- CGEventTap по-прежнему защищён системными разрешениями Accessibility/Input
  Monitoring.

Статический реверс локальных Caramba и Lang показал, что их Mac App Store
сборки одновременно sandboxed и используют CGEventTap/TIS. Поэтому переписывание
на IMKit не является предварительным техническим требованием. Это не гарантирует
решение App Review: sandboxed build всё равно нужно проверить на чистом Mac и
отправить на review с понятным объяснением назначения разрешений.

Нужны:

1. App ID `tech.sasha.qwertyswitch` в Apple Developer;
2. Apple Distribution certificate;
3. Mac App Store provisioning profile для этого App ID;
4. Mac Installer Distribution certificate;
5. карточка приложения и privacy answers в App Store Connect.

Сборка и упаковка:

```bash
APP_STORE_PROVISIONING_PROFILE="/path/QwertySwitcher.provisionprofile" \
APPLE_DISTRIBUTION="Apple Distribution: …" \
./Scripts/build.sh appstore

INSTALLER_IDENTITY="Mac Installer Distribution: …" \
./Scripts/appstore-package.sh
```

Полученный `build/QwertySwitcher-AppStore.pkg` загрузить через Transporter.
Перед `productbuild` скрипт проверяет strict code signature, Apple Distribution
authority, bundle ID, `com.apple.security.app-sandbox=true`, наличие и App ID
встроенного provisioning profile. Это локальный preflight, а не замена проверки
App Store Connect.

## Проверки перед распространением

```bash
plutil -lint Resources/Info.plist Resources/PrivacyInfo.xcprivacy
codesign --verify --deep --strict --verbose=2 "build/Qwerty Switcher.app"
codesign --display --entitlements - --xml "build/Qwerty Switcher.app"
spctl --assess --type execute --verbose=2 "build/Qwerty Switcher.app"
```

Для Developer ID дополнительно:

```bash
codesign --verify --verbose=2 "build/QwertySwitcher-0.3.0.dmg"
xcrun stapler validate "build/QwertySwitcher-0.3.0.dmg"
spctl --assess --type open --context context:primary-signature \
  --verbose=2 "build/QwertySwitcher-0.3.0.dmg"
```

Не считать релиз готовым, пока не пройдены: тесты ядра, ручные сценарии набора,
проверка на чистом пользовательском аккаунте, подпись, notarization или App Store
validation. Наличие сертификатов и решение App Review — внешние этапы, которые
локальный код не может подменить.

## Обновления (opt-in auto-updater, wave W1-B)

Network is used only if you enable update checks: once a day the app fetches
a single JSON from shulgin.is-a.dev and sends nothing about you. Оба флага
(«Проверять» и «Устанавливать автоматически») по умолчанию выключены.

- **Фид**: `https://shulgin.is-a.dev/store/downloads/qwertyswitcher/appcast.json`
  — `{"keyId","manifestBase64","signature"}`, подпись Ed25519 (CryptoKit)
  над сырыми байтами `manifestBase64` (не над пересобранным JSON). Публичные
  ключи `k1`/`k2` вшиты в `Services/Updates/UpdateKeyRing.swift`; приватные —
  ТОЛЬКО `~/.claude/secrets/qsw_update_ed25519_<id>.key`, в репозиторий не
  попадают никогда (гейт — `Scripts/release-secret-scan.sh`, паттерн `*_ed25519*`/`*.pem`/`*.key`).
- **Правила приёмки** (`UpdatePolicy.evaluate`): `build` строго больше
  установленного И не меньше `updates.lastSeenBuild` (анти-rollback);
  `minSystemVersion` выше текущей macOS → не предлагать; `validUntil` в
  прошлом → «фид устарел», не устанавливать.
- **Установка**: `UpdateStager` скачивает zip → sha256 → `ditto -x -k` в
  `~/Library/Application Support/QwertySwitcher/updates/<uuid>/` → проверяет
  `codesign --verify --deep --strict` И designated-requirement identity
  стейджа == identity установленной копии (та же редукция, что
  `Scripts/install.sh`'s `signing_identity_of`, — см. `DesignatedRequirement.swift`).
  Несовпадение identity (например, будущий переход на Developer ID) НИКОГДА
  не устанавливается автоматически — статус «скачайте вручную с витрины».
- **Хелпер**: `UpdateInstallerMode` (`--install-update`, диспетчер в
  `main.swift` до создания `NSApplication`) исполняет КОПИЮ `install.sh`,
  вынесенную из стейджевого бандла — тот же скрипт и те же TCC-инварианты,
  что при ручном `./Scripts/install.sh` (см. секцию выше и корневой
  `CLAUDE.md`). Откат при провале пост-синк проверки — `rsync -a --delete`
  из бэкапа, сделанного ДО синка. Контракт — `Tests/ReleaseScripts/update_helper_contract.sh`.
- **Релиз**: `./Scripts/release.sh [k1|k2]` собирает DMG+zip+appcast и
  копирует их в `~/Projects/web/store/downloads/`, но НИКОГДА сам не пушит и
  не публикует релиз — команды `git`/`gh release create` только печатаются.
