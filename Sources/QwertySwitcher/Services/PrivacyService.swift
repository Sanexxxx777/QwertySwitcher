import Foundation

/// Privacy & Security hardening. The only network client is the license
/// transport; there is no analytics or telemetry SDK.
final class PrivacyService {
    /// Privacy policy summary (shown in About view)
    static let policyText = """
    Qwerty Switcher — кратко о приватности:

    1. Весь ввод обрабатывается локально и никогда не покидает Mac.
    2. Приложение не хранит историю набора и сырые нажатия клавиш.
    3. Аналитики и телеметрии нет. Лицензионная проверка отправляет на сервер
       идентификатор Mac (hwid) и версию приложения —
       никогда набираемый текст.
    4. Для определения раскладки анализируется только текущее слово в памяти.
    5. Защищённые поля автоматически пропускаются и не буферизуются.

    Локально сохраняются:
    - настройки приложения;
    - слова-исключения, добавленные пользователем;
    - пары слов, которые пользователь явно подтвердил удалением и повторным вводом;
    - текстовые шаблоны, которые пользователь создал сам;
    - bundle ID исключённых приложений и per-app настройки;
    - числовые счётчики использования без содержимого текста.

    Буфер обмена читается только при включённой команде «Вставить без форматирования»,
    временно заменяется plain-text представлением и затем восстанавливается. Его
    содержимое не записывается в хранилище Qwerty Switcher.

    Удаление локальных данных:
    - обученные пары: «Исключения» → «Авто-обучение» → «Очистить»;
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
