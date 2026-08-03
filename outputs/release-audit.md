# Qwerty Switch — release audit

Дата: 2026-08-02

## Вердикт

- **Локальная beta:** собрана и готова к ручной on-device проверке.
- **Universal test DMG:** пересобран из текущих исходников и полностью проверен.
- **Публичная раздача вне App Store:** кодовый pipeline готов, но выпуск заблокирован
  отсутствующими Developer ID credentials и фактической notarization.
- **Mac App Store:** sandbox/build/package preflight готов; нужны Apple assets,
  реальный sandbox E2E, App Store Connect validation и решение App Review.

## Подтверждённое состояние

- Продукт `Qwerty Switch 0.3.0 (3)`, bundle ID `tech.sasha.qwertyswitch`.
- Canonical app: `build/Qwerty Switch.app`, 12 MB.
- Canonical image: `build/QwertySwitch-0.3.0.dmg`, 3.3 MB.
- DMG SHA-256:
  `9ca00d4a1000cb7a2db022d778e1d2e8c043cac0f19f16f404cb5ad98327c361`.
- Universal binary: `x86_64` + `arm64`; minimum macOS 13.0 у обоих срезов.
- Release test suite: `111 passed, 0 failed, 1 GUI-only skipped`.
- Локальная persistent self-signed подпись проходит strict `codesign`; Team ID не
  установлен, поэтому этот bundle не является публично доверенным Gatekeeper
  релизом.
- DMG checksum валиден. Read-only mount проверен: `.app`, Applications symlink и
  инструкция присутствуют; bundle идентичен canonical `.app` и имеет валидную
  подпись.
- Privacy manifest, Info.plist и оба entitlements-файла валидны. В исходниках не
  найдено сетевого/телеметрического клиента или кандидатов на секреты.

## Что исправлено в release tooling

- macOS 26 использует `diskutil image create from`; старый `hdiutil create` оставлен
  только как fallback для совместимости.
- Developer ID и App Store prerequisites проверяются до компиляции и до замены
  существующего canonical `.app`.
- Developer ID `.app` и финальный DMG получают secure timestamp; DMG имеет
  отдельный signing identifier и проверяется перед отправкой в notary service.
- Notarization target `dmg` отправляет, stapled и Gatekeeper-assess-ит один и тот
  же финальный файл.
- App Store packager не создаёт `.pkg`, пока не проверит embedded profile, App ID,
  bundle ID, sandbox entitlement, strict Apple Distribution signature и installer
  identity.

## Внешние блокеры

1. На этом Mac нет валидных `Developer ID Application`, `Apple Distribution` и
   Installer Distribution identities. Их нельзя сгенерировать кодом проекта.
2. Для notarization нужен Keychain profile с Apple credentials; секреты не
   запрашивались и не сохранялись в репозитории.
3. Для App Store нужны зарегистрированный App ID/profile, карточка приложения,
   privacy/support URLs и upload через Apple tooling.
4. Обязателен ручной тест на чистом аккаунте: permissions, Russian/RussianWin,
   RU↔EN, регистр, Undo, secure fields и смена фокуса во время замены.

Сборка не опубликована и не загружена во внешние сервисы.
