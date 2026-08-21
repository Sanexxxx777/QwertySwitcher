# KeyRay: static reverse capsule и clean-room граница

Дата наблюдения: 2026-08-21.

## Scope

- Основание: публичный сайт и локальные файлы, явно переданные владельцем.
- PRIMARY: macOS desktop binary; secondary: публичный сайт.
- Разрешённый метод: read-only static analysis.
- Не выполнялось: запуск, установка, patching, login, активное probing, обход
  лицензии, отправка файлов во внешние сервисы.

Target identity:

- `KeyRay.dmg`: 31,415,706 bytes, SHA-256
  `c20d78f83d6230d9ea247a39db5eaf40921f75f303e73dbeb1954e2587f0d3c1`.
- Сохранённая страница: SHA-256
  `08f3e22a09abfc013303a26b6d869eb5e01259faf5399bf10970bd964713856a`.
- Извлечённый ранее app binary: SHA-256
  `c2e560fb9b1743cfe467920c43b5cb8c3a8acde2d63fa162f24ac0e6a9dca75d`.

## Evidence

| ID | Level | Redacted result | Coverage |
|---|---|---|---|
| E-001 | metadata | DMG hash/size выше | Идентичность исследованного образа |
| E-002 | static | Site/Markdown заявляют auto-layout, выделенный текст, app exclusions, hotkeys, sticky Shift, register conversion, local voice and AI translation | Публичный product surface; не доказывает runtime |
| E-003 | static | `Info.plist`: KeyRay 2.1.1 (1251), `gg.KeyRay`, minimum macOS 13.4, universal app | Bundle identity и compatibility |
| E-004 | metadata | Valid Developer ID signature with hardened runtime and 2026-08-12 timestamp; App Sandbox entitlement absent | Подпись/entitlements; notarization осталась не доказана |
| E-005 | static | Imports/disassembly reference CGEvent tap, TIS, AX, AVAudioEngine and IOKit | Реализованные OS boundaries; точный decision algorithm не доказан |
| E-006 | static | Sparkle 2.8.0 bundled; production resource points to `appcast-dev.xml` | Update architecture и release-config risk |
| E-007 | static | Small EN/RU product dictionaries plus bundled Hunspell dictionaries | Dictionary-assisted detection; scoring/order не доказаны |
| E-008 | static | sherpa-onnx/ASR symbols and CDN model archive references; models not bundled | Separate downloadable speech-engine path; runtime/offline behavior не доказано |
| E-009 | static | Release bundle contains `env.local.example` with non-empty credential-like values: **present** | Supply-chain leak risk; values intentionally omitted |
| E-010 | observed web | `/policy` says typing is local, but user dictionaries are periodically transmitted; selected text goes through developer servers to external processors | Declared privacy/data boundaries as of observation date |

Safe reproduction surface: `shasum -a 256`, `file`, `plutil`, `codesign -dvvv
--entitlements :-`, `otool -L`, `nm -u`, and narrowly scoped `strings`. Static
parsers do not prove user-visible behavior.

## Static-derived model

```text
physical input
  -> global event interception
  -> secure-field/app/profile gates
  -> current-word/layout classification
  -> layout/case/snippet transformation
  -> synthetic retype or selected-text replacement

microphone
  -> audio capture
  -> separately downloaded ASR model
  -> local transcription candidate
  -> focused-field insertion

explicit selected text
  -> translation/AI command
  -> developer server
  -> external processor
  -> replacement/result
```

Confidence is high for the OS/dependency boundaries and medium for feature-level
flows inferred from strings/resources. Runtime equivalence was not tested.

## Clean-room specification used by Qwerty Switcher

No proprietary source, artwork, dictionaries, models, UI copy, or credentials
were transferred.

| Spec | Independent behavior | Oracle | Status |
|---|---|---|---|
| S-001 | Per-app profile independently blocks auto-switch, instant correction, or hotkeys | Toggle each flag and verify only its branch is denied | Implemented |
| S-002 | Timed pause persists a resume deadline and resumes once | Reconcile before/after deadline; manual toggle cancels deadline | Implemented |
| S-003 | Versioned settings backup has an explicit allowlist and excludes license/device/log state | Round-trip valid JSON; reject bad version/counts/IDs | Implemented |
| S-004 | Local letter-only trigger expands to a user-authored multiline snippet at a safe boundary | Case-insensitive lookup; one backspace/retype transaction | Implemented |
| S-005 | Optional conservative case normalization fixes accidental double-cap and sentence start without touching acronyms/camelCase/tokens | `ПРивет -> Привет`, preserve `USA`, `iPhone`, `hello-world` | Implemented |
| S-006 | Opt-in voice input must prove Russian support and offline operation before insertion | Network-denied transcription, WER/latency/RAM/model-size measurements | Spike only |

## Security/release findings

- Qwerty release scripts now fail closed on env/private-key files and
  credential-like assignments before app/DMG packaging.
- Qwerty privacy declaration now truthfully includes the linked device ID used
  by licensing.
- Qwerty's current raw Mac identifier cannot be changed unilaterally: existing
  signed licenses are server-bound to it. Migration requires a coordinated
  server protocol and separate deployment approval.

## Not proved

- KeyRay's exact scoring, typo algorithm, ASR accuracy, offline guarantee,
  network request shapes, and behavior in real applications.
- Notarization: the local `spctl` check returned an internal error.
- Whether credential-like values from E-009 are live. They were not used or
  disclosed.

Next decisive step, only if still needed: run KeyRay in a disposable VM with no
host secrets/shared folders and a deny-by-default network policy. This requires
separate approval.
