# Qwerty Switch — отчёт проверки исправлений

Дата проверки: 2026-08-02

## Классификация

`FIX_PROVEN` для перечисленных ниже дефектов.

Для каждого исправления был получен воспроизводимый красный сигнал до изменения
поведения, затем тот же тест или release-контракт стал зелёным. Эта классификация
не распространяется на интерактивный macOS GUI-сценарий: создание живого
`CGEvent`, выдача Accessibility/Input Monitoring и печать в сторонних приложениях
остаются отдельной on-device проверкой.

## Доказанные исправления

1. **Символ после слова зависел от US-карты.** На установленной RussianWin
   keycode 44 возвращал `/` вместо layout-символа, а Shift+2 — `@` вместо `"`.
   После исправления trailing-символ берётся через TIS активной раскладки; US-map
   остался только fallback.
2. **Shift+б/ю в русской раскладке ошибочно считались пунктуацией.** Красные
   регрессии подтвердили, что TIS возвращает буквы; после исправления обе клавиши
   остаются частью слова.
3. **Повреждённый Bloom cache принимался при недостаточном bit storage.** Loader
   теперь требует точное `(bitCount + 63) / 64` количество слов.
4. **Пустой словарь мог привести к делению на ноль/ловушке при расчёте Bloom.**
   Красный прогон: `109 passed, 1 failed, 1 skipped`; зелёный: `111/0/1`.
5. **Secure Input activation скрывалась cached-false окном 500 мс.** Красный
   runtime-прогон показал старое `false` и один system check; теперь `false` не
   кэшируется, а положительный результат кэшируется fail-closed.
6. **Cmd/Ctrl/Option оставляли старый word/Undo-контекст.** Красные policy-тесты
   для Option и Command стали зелёными после явной invalidation перед early return.
7. **Замена продолжалась после клика/смены приложения.** Потокобезопасный
   cancellation token теперь проверяется до layout switch и между отправляемыми
   backspace/Unicode-событиями. Cancelled-операция не пишет статистику и не
   восстанавливает устаревший Undo.
8. **Публичный DMG pipeline мог пересобрать self-signed артефакт после Developer
   ID шага и не подписывал сам DMG.** Контракт сначала падал; теперь certificate
   проверяется до сборки, `.app` и финальный DMG подписываются с secure timestamp,
   и именно этот DMG проверяется, notarize-ится и stapled.
9. **App Store preflight был недостаточным и выполнялся слишком поздно.** Теперь
   profile/certificate проверяются до компиляции и замены текущего `.app`, а перед
   `productbuild` валидируются strict signature, Apple Distribution authority,
   bundle ID, sandbox entitlement и App ID embedded profile.

Контрольный runtime red-прогон пунктов 5–7 дал ровно `104 passed, 5 failed,
1 skipped`; после исправлений — `109 passed, 0 failed, 1 skipped`.

## Финальная проверка артефактов

- `./Scripts/test.sh`: `111 passed, 0 failed, 1 skipped`.
- Тот же suite из release-бинарника внутри `.app`: `111/0/1`.
- Universal Mach-O: `x86_64` + `arm64`; minimum OS обоих срезов — macOS 13.0.
- `codesign --verify --deep --strict`: passed.
- `plutil -lint`, `bash -n`, оба release-контракта и `git diff --check`: passed.
- DMG создан поддерживаемым `diskutil image create from`; `hdiutil verify`:
  checksum valid.
- Read-only mount содержит `.app`, Applications symlink и русскую инструкцию;
  `diff -rq` между собранным и вложенным bundle не нашёл различий, strict
  signature вложенного `.app` прошла.
- Source-only secret scan и network-client scan: 0 кандидатов.

## Не подменённая автоматикой проверка

Одна проверка создания синтетического `CGEvent` помечена `SKIP`, потому что на
этом macOS build она требует живой GUI app session. До публичного релиза нужно на
обычном пользовательском аккаунте выдать новому bundle ID разрешения и вручную
проверить RU↔EN, регистр, RussianWin, Undo, password fields, Telegram/Safari/
VSCode/Terminal и клик/быстрый ввод во время замены.

Локально отсутствуют действующие Developer ID, Apple Distribution и Installer
Distribution identities. Поэтому actual Apple notarization, App Store `.pkg`
и App Review не заявлены как выполненные; доказан локальный pipeline и его
fail-fast/validation contract.
