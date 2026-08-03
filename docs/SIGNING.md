# Qwerty Switcher: подпись и публикация

Актуальные идентификаторы:

- продукт: `Qwerty Switcher`;
- bundle ID: `tech.sasha.qwertyswitch`;
- внутренний Swift executable: `QwertySwitcher` (переименован из `SashaSwitcher` 03.08.2026; это не видно пользователю);
- signing identity: "SashaSwitcher Developer" (не переименовывать — смена сбросит TCC);
- версия после ребрендинга: `0.3.0` (`CFBundleVersion = 3`).

## 1. Локальная beta

Один раз создаётся self-signed certificate. Его старое имя намеренно сохранено,
чтобы не ломать уже настроенные Mac разработчиков.

```bash
cd ~/Projects/SashaSwitcher
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

App Store-сборка подготовлена как отдельный sandboxed вариант:

- `Resources/QwertySwitcher.appstore.entitlements` включает только App Sandbox;
- сеть, Apple Events, JIT и debug-entitlements не запрашиваются;
- `PrivacyInfo.xcprivacy` объявляет отсутствие tracking/collection и использование
  UserDefaults для функций приложения;
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
