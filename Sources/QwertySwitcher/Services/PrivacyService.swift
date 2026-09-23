import Foundation

/// Privacy & Security hardening. Network is used only if you enable update
/// checks: once a day the app fetches a single JSON from shulgin.is-a.dev
/// and sends nothing about you — there is no analytics or telemetry.
final class PrivacyService {
    /// Privacy policy summary (shown in About view)
    static let policyText = """
    Qwerty Switcher — кратко о приватности:

    1. Весь ввод обрабатывается локально и никогда не покидает Mac.
    2. Приложение не хранит историю набора. Единственное исключение —
       выключенный по умолчанию «Подробный лог»: пока вы его не включите,
       нажатия клавиш на диск не попадают. Включённым он пишет коды клавиш
       в файл, доступный только вашей учётной записи; кнопка «Собрать
       отчёт» эти строки вырезает, так что в отправленном архиве набранного
       текста нет.
    3. Сеть используется только если вы включите проверку обновлений в
       настройках — раз в сутки один запрос к shulgin.is-a.dev, без каких-либо
       данных о вас. Аналитики и телеметрии нет.
    4. Для определения раскладки анализируется текущее слово. В памяти (не на
       диске) держатся ещё язык трёх последних слов и последнее слово — оно
       нужно для Double Shift.
    5. Защищённые поля автоматически пропускаются и не буферизуются.

    Локально сохраняются:
    - настройки приложения;
    - слова-исключения, добавленные пользователем;
    - пары слов, которые пользователь явно подтвердил удалением и повторным вводом;
    - текстовые шаблоны, которые пользователь создал сам;
    - bundle ID исключённых приложений и per-app настройки;
    - числовые счётчики использования без содержимого текста;
    - пары слов, которые вы исправляли через Double Shift, с датой и
      приложением (до 300); после второго исправления пара чинится сама;
    - слова, которые вы часто набираете и не исправляете (личный частотник,
      до 2000 слов со счётчиками), — чтобы программа их не трогала.
    Обучение выключается тумблером «Учиться на моих исправлениях».

    Буфер обмена используется в двух случаях: команда «Вставить без
    форматирования» и Double Shift по выделенному тексту в приложениях,
    которые не отдают выделение напрямую (выделение копируется, исправленный
    текст вставляется). В обоих случаях прежнее содержимое буфера затем
    восстанавливается и в хранилище Qwerty Switcher не записывается.
    Менеджеры буфера обмена могут успеть запомнить промежуточное значение.

    Удаление локальных данных:
    - обученные пары: «Исключения» → «Авто-обучение» → «Очистить»;
    - выученные слова и личный словарь: «Исключения» → «Обучение» → «Забыть все»
      и «Забыть всё»;
    - отдельные слова и приложения удаляются в соответствующих вкладках;
    - все настройки, статистику, кэш, логи и регистрацию автозапуска удаляет кнопка
      «Удалить все локальные данные» в этом окне после отдельного подтверждения.
    """

    /// Safe representation for diagnostics: preserves only length.
    static func sanitize(_ word: String) -> String {
        "<redacted length=\(word.count)>"
    }

    /// Read-only audit. It reports only a count and never deletes user data silently.
    @discardableResult
    static func auditStorage() -> [String] {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        let suspiciousKeys = allKeys.filter { key in
            key.contains("keystroke") || key.contains("typed") ||
            key.contains("password") || key.contains("clipboard") ||
            key.contains("keylog")
        }

        if !suspiciousKeys.isEmpty {
            NSLog("[PRIVACY ALERT] Suspicious UserDefaults key count: \(suspiciousKeys.count)")
        }
        return suspiciousKeys
    }

    /// Called only after a user confirms the destructive action in an NSAlert.
    static func deleteAllLocalData() throws {
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: AppIdentity.bundleIdentifier)
        defaults.removePersistentDomain(forName: AppIdentity.legacyBundleIdentifier)

        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return
        }
        let directories = [
            library.appendingPathComponent("Application Support/QwertySwitcher", isDirectory: true),
            library.appendingPathComponent("Application Support/SashaSwitcher", isDirectory: true),
            library.appendingPathComponent("Logs/QwertySwitcher", isDirectory: true),
            library.appendingPathComponent("Logs/SashaSwitcher", isDirectory: true),
        ]
        for directory in directories where fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
    }
}
