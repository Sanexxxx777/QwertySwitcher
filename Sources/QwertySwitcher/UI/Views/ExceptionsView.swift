import SwiftUI

struct ExceptionsView: View {
    @ObservedObject var viewModel: ExceptionsViewModel
    @Environment(\.appTheme) private var theme
    @State private var newWord = ""
    @State private var selectedTab = 0
    @State private var selectedApps: Set<String> = []
    @State private var newSnippetTrigger = ""
    @State private var newSnippetReplacement = ""
    @State private var showRemoveAllLearnedConfirm = false
    @State private var showRemoveAllPersonalConfirm = false
    @State private var personalDictionaryExpanded = false
    @State private var personalDictionaryShowAll = false
    @State private var showPersonalDictionaryShowAllConfirm = false

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 460, height: 440)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Исключения")
                        .font(.appText(19, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    Text("Что Qwerty Switcher не должен исправлять")
                        .font(.appText(11))
                        .foregroundColor(theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Слова").tag(0)
                Text("Приложения").tag(1)
                Text("Авто-обучение").tag(2)
                Text("Шаблоны").tag(3)
                Text("Обучение").tag(4)
            }
            .pickerStyle(.segmented)
            .tint(theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Content
            Group {
                switch selectedTab {
                case 0: wordExceptionsTab
                case 1: appExceptionsTab
                case 2: autoLearnedTab
                case 3: snippetsTab
                case 4: learningTab
                default: EmptyView()
                }
            }
        }
    }

    // MARK: - Word Exceptions

    private var wordExceptionsTab: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Добавить слово...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .foregroundColor(theme.textPrimary)
                    .onSubmit { addWord() }

                Button("Добавить") { addWord() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)

            List {
                ForEach(viewModel.wordExceptions.sorted(), id: \.self) { word in
                    HStack {
                        Text(word)
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Button(action: { withAnimation { viewModel.removeWord(word) } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить слово \(word)")
                    }
                    .listRowBackground(theme.bgCard)
                }
            }
            .scrollContentBackground(.hidden)

            Text("\(viewModel.wordExceptions.count) слов в исключениях")
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .padding(.bottom, 8)
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        withAnimation { viewModel.addWord(word) }
        newWord = ""
    }

    // MARK: - App Exceptions

    private var appExceptionsTab: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Профили приложений")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Button("+ Текущее приложение") { withAnimation { viewModel.addCurrentApp() } }
                    .font(.caption)
                    .foregroundColor(theme.accent)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Button("Выбрать все") {
                    selectedApps = Set(viewModel.appProfiles.keys)
                }
                .disabled(viewModel.appProfiles.isEmpty)

                Menu("Для выбранных") {
                    Button("Запретить автопереключение") {
                        viewModel.setFlag(.autoSwitch, blocked: true, for: selectedApps)
                    }
                    Button("Запретить мгновенную коррекцию") {
                        viewModel.setFlag(.instantCorrection, blocked: true, for: selectedApps)
                    }
                    Button("Запретить горячие клавиши") {
                        viewModel.setFlag(.hotkeys, blocked: true, for: selectedApps)
                    }
                    Divider()
                    Button("Разрешить все функции") {
                        viewModel.allowAll(for: selectedApps)
                        selectedApps.removeAll()
                    }
                    Button("Удалить профили") {
                        viewModel.removeApps(selectedApps)
                        selectedApps.removeAll()
                    }
                }
                .disabled(selectedApps.isEmpty)

                Spacer()
                Text("A · I · H")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .help("A — автопереключение, I — мгновенная коррекция, H — горячие клавиши")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 16)

            List {
                ForEach(viewModel.appProfiles.keys.sorted(), id: \.self) { bundleID in
                    let profile = viewModel.appProfiles[bundleID] ?? AppProfile()
                    HStack {
                        Button {
                            if selectedApps.contains(bundleID) {
                                selectedApps.remove(bundleID)
                            } else {
                                selectedApps.insert(bundleID)
                            }
                        } label: {
                            Image(systemName: selectedApps.contains(bundleID) ? "checkmark.square.fill" : "square")
                                .foregroundColor(selectedApps.contains(bundleID) ? theme.accent : theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Выбрать профиль \(bundleID)")

                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()

                        ProfileFlagButton(
                            label: "A", help: "Запретить автопереключение",
                            isBlocked: profile.blockAutoSwitch
                        ) { viewModel.toggleFlag(.autoSwitch, for: bundleID) }
                        ProfileFlagButton(
                            label: "I", help: "Запретить мгновенную коррекцию",
                            isBlocked: profile.blockInstantCorrection
                        ) { viewModel.toggleFlag(.instantCorrection, for: bundleID) }
                        ProfileFlagButton(
                            label: "H", help: "Запретить горячие клавиши",
                            isBlocked: profile.blockHotkeys
                        ) { viewModel.toggleFlag(.hotkeys, for: bundleID) }

                        Button(action: {
                            withAnimation { viewModel.removeApp(bundleID) }
                            selectedApps.remove(bundleID)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить приложение \(bundleID)")
                    }
                    .listRowBackground(theme.bgCard)
                }
            }
            .scrollContentBackground(.hidden)

            Text("\(viewModel.appProfiles.count) профилей · цветная буква означает запрет")
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Auto-Learned

    private var autoLearnedTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Запомненные исправления:")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                HelpIcon(text: "Слово попадает сюда автоматически: если ты стираешь наше "
                    + "исправление backspace'ом и вводишь заново то же самое, Qwerty Switcher "
                    + "больше не будет его трогать.")
                Spacer()
                if !viewModel.autoLearned.isEmpty {
                    Button("Очистить") { withAnimation { viewModel.clearAutoLearned() } }
                        .font(.caption)
                        .foregroundColor(theme.accentDeep)
                }
            }
            .padding(.horizontal, 16)

            if viewModel.autoLearned.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 32))
                        .foregroundColor(theme.textSecondary.opacity(0.3))
                    Text("Пока пусто")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                    Text("Исключение появится после полного удаления\nисправления и точного повторного ввода")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List {
                    ForEach(Array(viewModel.autoLearned.keys.sorted()), id: \.self) { key in
                        HStack {
                            Text(key)
                                .foregroundColor(theme.textPrimary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(theme.textSecondary.opacity(0.5))
                            Text(viewModel.autoLearned[key] ?? "")
                                .foregroundColor(theme.textSecondary)
                            Spacer()
                            Button(action: { withAnimation { viewModel.removeAutoLearned(key) } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(theme.textSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Удалить запомнённое исправление \(key)")
                        }
                        .listRowBackground(theme.bgCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var snippetsTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Команда, например addr", text: $newSnippetTrigger)
                    .textFieldStyle(.roundedBorder)
                Button("Добавить") {
                    if viewModel.addSnippet(
                        trigger: newSnippetTrigger, replacement: newSnippetReplacement
                    ) {
                        newSnippetTrigger = ""
                        newSnippetReplacement = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(
                    newSnippetTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newSnippetReplacement.isEmpty
                )
            }
            .padding(.horizontal, 16)

            TextEditor(text: $newSnippetReplacement)
                .font(.system(size: 12))
                .foregroundColor(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 72)
                .background(theme.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if newSnippetReplacement.isEmpty {
                        Text("Текст замены; можно несколько строк")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary.opacity(0.65))
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)

            List {
                ForEach(viewModel.snippets.keys.sorted(), id: \.self) { trigger in
                    HStack(spacing: 8) {
                        Text(trigger)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.accentDeep)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary.opacity(0.5))
                        Text(viewModel.snippets[trigger] ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(2)
                        Spacer()
                        Button(action: { viewModel.removeSnippet(trigger) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить шаблон \(trigger)")
                    }
                    .listRowBackground(theme.bgCard)
                }
            }
            .scrollContentBackground(.hidden)

            Text("Срабатывает после пробела или знака · данные остаются на Mac")
                .font(.caption)
                .foregroundColor(theme.textSecondary)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Learning (Mechanisms A + C, learning_spec.md)

    private var learningTab: some View {
        VStack(spacing: 8) {
            learnedWordsSection
            Divider().padding(.horizontal, 16)
            personalDictionarySection
            Spacer(minLength: 0)
        }
        .confirmationDialog(
            "Забыть все выученные слова?", isPresented: $showRemoveAllLearnedConfirm, titleVisibility: .visible
        ) {
            Button("Забыть все", role: .destructive) {
                withAnimation { viewModel.removeAllLearnedWords() }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(
            "Забыть весь личный словарь?", isPresented: $showRemoveAllPersonalConfirm, titleVisibility: .visible
        ) {
            Button("Забыть всё", role: .destructive) {
                withAnimation { viewModel.removeAllPersonalWords() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это слова, которые вы набирали чаще всего — их не восстановить.")
        }
        .confirmationDialog(
            "Это история вашего ввода", isPresented: $showPersonalDictionaryShowAllConfirm, titleVisibility: .visible
        ) {
            Button("Показать все") { personalDictionaryShowAll = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Личный словарь — это слова, которые вы печатали на этом Mac. Показать полный список?")
        }
    }

    /// Mechanism A (`LearnedWordsStore`): words the owner fixed with Double
    /// Shift twice within 30 days, now corrected silently and automatically.
    private var learnedWordsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Выученные слова:")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                HelpIcon(text: "Слово попадает сюда, если ты дважды исправил его Double Shift "
                    + "в течение 30 дней. После этого Qwerty Switcher исправляет его сам, без "
                    + "твоего участия.")
                Spacer()
                if !viewModel.learnedWords.isEmpty {
                    Button("Забыть все") { showRemoveAllLearnedConfirm = true }
                        .font(.caption)
                        .foregroundColor(theme.accentDeep)
                }
            }
            .padding(.horizontal, 16)

            if viewModel.learnedWords.isEmpty {
                VStack(spacing: 2) {
                    Text("Пока пусто")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                    Text("Слово появится здесь после второго исправления Double Shift")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                List {
                    ForEach(viewModel.learnedWords) { entry in
                        HStack(spacing: 8) {
                            LanguageBadge(lang: entry.lang)
                            Text(entry.word)
                                .foregroundColor(theme.textPrimary)
                            Text("×\(entry.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.textSecondary)
                            if let originApp = entry.originApp {
                                Image(systemName: "app")
                                    .font(.caption2)
                                    .foregroundColor(theme.textSecondary.opacity(0.5))
                                    .help(originApp)
                            }
                            Spacer()
                            Button(action: { withAnimation { viewModel.removeLearnedWord(entry) } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(theme.textSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Забыть слово \(entry.word)")
                        }
                        .listRowBackground(theme.bgCard)
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 110)
            }
        }
    }

    /// Mechanism C (`PersonalFrequencyStore`): collapsed by default (just a
    /// count) — this is a passive record of everything the owner typed, not
    /// something they explicitly confirmed like Mechanism A.
    private var personalDictionarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { withAnimation { personalDictionaryExpanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: personalDictionaryExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Личный словарь: \(viewModel.personalWordsCount) слов")
                            .font(.caption)
                    }
                    .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                HelpIcon(text: "Слова, которые ты часто печатал и они прошли без исправления. "
                    + "Используются только на границе слова. Это история твоего набора — "
                    + "хранится только на этом Mac и не входит в резервную копию настроек.")
                Spacer()
                if viewModel.personalWordsCount > 0 {
                    Button("Забыть всё") { showRemoveAllPersonalConfirm = true }
                        .font(.caption)
                        .foregroundColor(theme.accentDeep)
                }
            }
            .padding(.horizontal, 16)

            if personalDictionaryExpanded {
                let rows = personalDictionaryShowAll ? viewModel.allPersonalWords : viewModel.personalWordsTop20
                if rows.isEmpty {
                    Text("Пока пусто")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary.opacity(0.6))
                        .padding(.horizontal, 16)
                } else {
                    List {
                        ForEach(rows) { entry in
                            HStack(spacing: 8) {
                                LanguageBadge(lang: entry.lang)
                                Text(entry.word)
                                    .foregroundColor(theme.textPrimary)
                                Text("×\(entry.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.textSecondary)
                                Spacer()
                                Button(action: { withAnimation { viewModel.removePersonalWord(entry) } }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(theme.textSecondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Забыть слово \(entry.word)")
                            }
                            .listRowBackground(theme.bgCard)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: 90)

                    if !personalDictionaryShowAll && viewModel.personalWordsCount > viewModel.personalWordsTop20.count {
                        Button("Показать все (\(viewModel.personalWordsCount))") {
                            showPersonalDictionaryShowAllConfirm = true
                        }
                        .font(.system(size: 11))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

private struct ProfileFlagButton: View {
    @Environment(\.appTheme) private var theme
    let label: String
    let help: String
    let isBlocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isBlocked ? theme.accentDeep : theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(isBlocked ? theme.accent.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Compact RU/EN badge for a learned/personal-dictionary word row — same
/// monospaced-letter-on-tinted-background language as `ProfileFlagButton`
/// above, just always "active" (no on/off state to show).
private struct LanguageBadge: View {
    @Environment(\.appTheme) private var theme
    let lang: String

    var body: some View {
        Text(lang.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(theme.accentDeep)
            .frame(width: 22, height: 16)
            .background(theme.accent.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

enum AppProfileFlag {
    case autoSwitch
    case instantCorrection
    case hotkeys
}

/// A row for the "Выученные слова" (Mechanism A) list — one active
/// `LearnedWordsStore` entry, split out of its `"lang:word"` composite key.
struct LearnedWordRow: Identifiable, Equatable {
    let id: String
    let word: String
    let lang: String
    let count: Int
    let originApp: String?
}

/// A row for the "Личный словарь" (Mechanism C) list.
struct PersonalWordRow: Identifiable, Equatable {
    let id: String
    let word: String
    let lang: String
    let count: Int
}

final class ExceptionsViewModel: ObservableObject {
    private let exceptionsService: ExceptionsService
    private let snippetService: SnippetService
    // Optional — NOT wired to a live default (a fresh `LearnedWordsStore()`/
    // `PersonalFrequencyStore()` here would be a second, independent
    // in-memory instance racing the real one `KeyboardMonitor` owns and
    // flushes; per-entry delete / "Забыть все" through a throwaway instance
    // would silently not persist). `nil` renders an honest empty section
    // instead of a data-loss trap. See the file's task report for the
    // one-line call-site change (outside this file's boundary) that wires
    // the real instances through.
    private let learnedWordsStore: LearnedWordsStore?
    private let personalFrequencyStore: PersonalFrequencyStore?

    @Published var wordExceptions: Set<String>
    @Published var appProfiles: [String: AppProfile]
    @Published var autoLearned: [String: String]
    @Published var snippets: [String: String]
    @Published var learnedWords: [LearnedWordRow]
    @Published var personalWordsCount: Int
    @Published var personalWordsTop20: [PersonalWordRow]
    @Published var allPersonalWords: [PersonalWordRow]

    init(
        exceptionsService: ExceptionsService, snippetService: SnippetService = SnippetService(),
        learnedWordsStore: LearnedWordsStore? = nil, personalFrequencyStore: PersonalFrequencyStore? = nil
    ) {
        self.exceptionsService = exceptionsService
        self.snippetService = snippetService
        self.learnedWordsStore = learnedWordsStore
        self.personalFrequencyStore = personalFrequencyStore
        self.wordExceptions = exceptionsService.wordExceptions
        self.appProfiles = exceptionsService.appProfiles
        self.autoLearned = exceptionsService.autoLearned
        self.snippets = snippetService.snippets
        self.learnedWords = Self.computeLearnedWords(learnedWordsStore)
        self.personalWordsCount = personalFrequencyStore?.count ?? 0
        let personalWords = Self.computePersonalWords(personalFrequencyStore)
        self.allPersonalWords = personalWords
        self.personalWordsTop20 = Array(personalWords.sorted { $0.count > $1.count }.prefix(20))
    }

    func addWord(_ word: String) {
        exceptionsService.addWordException(word)
        wordExceptions = exceptionsService.wordExceptions
    }

    func removeWord(_ word: String) {
        exceptionsService.removeWordException(word)
        wordExceptions = exceptionsService.wordExceptions
    }

    func addCurrentApp() {
        if let bundleID = exceptionsService.currentAppBundleID() {
            exceptionsService.addAppException(bundleID)
            appProfiles = exceptionsService.appProfiles
        }
    }

    func removeApp(_ bundleID: String) {
        exceptionsService.removeProfiles(for: [bundleID])
        appProfiles = exceptionsService.appProfiles
    }

    func removeApps(_ bundleIDs: Set<String>) {
        exceptionsService.removeProfiles(for: bundleIDs)
        appProfiles = exceptionsService.appProfiles
    }

    func toggleFlag(_ flag: AppProfileFlag, for bundleID: String) {
        var profile = appProfiles[bundleID] ?? AppProfile()
        switch flag {
        case .autoSwitch: profile.blockAutoSwitch.toggle()
        case .instantCorrection: profile.blockInstantCorrection.toggle()
        case .hotkeys: profile.blockHotkeys.toggle()
        }
        exceptionsService.setProfile(profile, for: bundleID)
        appProfiles = exceptionsService.appProfiles
    }

    func setFlag(_ flag: AppProfileFlag, blocked: Bool, for bundleIDs: Set<String>) {
        for bundleID in bundleIDs {
            var profile = appProfiles[bundleID] ?? AppProfile()
            switch flag {
            case .autoSwitch: profile.blockAutoSwitch = blocked
            case .instantCorrection: profile.blockInstantCorrection = blocked
            case .hotkeys: profile.blockHotkeys = blocked
            }
            exceptionsService.setProfile(profile, for: bundleID)
        }
        appProfiles = exceptionsService.appProfiles
    }

    func allowAll(for bundleIDs: Set<String>) {
        exceptionsService.removeProfiles(for: bundleIDs)
        appProfiles = exceptionsService.appProfiles
    }

    func clearAutoLearned() {
        exceptionsService.autoLearned = [:]
        autoLearned = [:]
    }

    func removeAutoLearned(_ key: String) {
        exceptionsService.removeAutoLearned(key)
        autoLearned = exceptionsService.autoLearned
    }

    @discardableResult
    func addSnippet(trigger: String, replacement: String) -> Bool {
        guard snippetService.setSnippet(trigger: trigger, replacement: replacement) else {
            return false
        }
        snippets = snippetService.snippets
        return true
    }

    func removeSnippet(_ trigger: String) {
        snippetService.removeSnippet(trigger: trigger)
        snippets = snippetService.snippets
    }

    // MARK: - Learning (Mechanisms A + C)

    func removeLearnedWord(_ entry: LearnedWordRow) {
        learnedWordsStore?.unlearn(word: entry.word, lang: entry.lang)
        learnedWords = Self.computeLearnedWords(learnedWordsStore)
    }

    func removeAllLearnedWords() {
        learnedWordsStore?.removeAll()
        learnedWords = Self.computeLearnedWords(learnedWordsStore)
    }

    func removePersonalWord(_ entry: PersonalWordRow) {
        personalFrequencyStore?.unlearn(word: entry.word, lang: entry.lang)
        refreshPersonalWords()
    }

    func removeAllPersonalWords() {
        personalFrequencyStore?.removeAll()
        refreshPersonalWords()
    }

    private func refreshPersonalWords() {
        let personalWords = Self.computePersonalWords(personalFrequencyStore)
        allPersonalWords = personalWords
        personalWordsTop20 = Array(personalWords.sorted { $0.count > $1.count }.prefix(20))
        personalWordsCount = personalFrequencyStore?.count ?? 0
    }

    /// Only the ACTIVE subset (spec: "Список активных записей
    /// LearnedWordsStore") — an entry the owner confirmed once but hasn't
    /// promoted yet isn't something Qwerty Switcher is silently correcting,
    /// so it has nothing useful to show or delete here.
    private static func computeLearnedWords(_ store: LearnedWordsStore?) -> [LearnedWordRow] {
        guard let store else { return [] }
        return store.allEntries.compactMap { key, entry -> LearnedWordRow? in
            guard let split = splitStoreKey(key), store.isActive(word: split.word, lang: split.lang) else {
                return nil
            }
            return LearnedWordRow(
                id: key, word: split.word, lang: split.lang, count: entry.count, originApp: entry.originApp
            )
        }.sorted { $0.word < $1.word }
    }

    /// All tracked words, including in-memory-only `count == 1` entries —
    /// matches `PersonalFrequencyStore.allEntries`'s own doc comment ("for
    /// UI... unlike what actually reaches disk").
    private static func computePersonalWords(_ store: PersonalFrequencyStore?) -> [PersonalWordRow] {
        guard let store else { return [] }
        return store.allEntries.compactMap { key, entry -> PersonalWordRow? in
            guard let split = splitStoreKey(key) else { return nil }
            return PersonalWordRow(id: key, word: split.word, lang: split.lang, count: entry.count)
        }
    }

    private static func splitStoreKey(_ key: String) -> (lang: String, word: String)? {
        guard let separator = key.firstIndex(of: ":") else { return nil }
        let lang = String(key[key.startIndex..<separator])
        let word = String(key[key.index(after: separator)...])
        guard !lang.isEmpty, !word.isEmpty else { return nil }
        return (lang, word)
    }
}
