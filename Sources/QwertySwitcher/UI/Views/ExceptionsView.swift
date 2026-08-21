import SwiftUI

struct ExceptionsView: View {
    @ObservedObject var viewModel: ExceptionsViewModel
    @Environment(\.appTheme) private var theme
    @State private var newWord = ""
    @State private var selectedTab = 0
    @State private var selectedApps: Set<String> = []
    @State private var newSnippetTrigger = ""
    @State private var newSnippetReplacement = ""

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

enum AppProfileFlag {
    case autoSwitch
    case instantCorrection
    case hotkeys
}

final class ExceptionsViewModel: ObservableObject {
    private let exceptionsService: ExceptionsService
    private let snippetService: SnippetService

    @Published var wordExceptions: Set<String>
    @Published var appProfiles: [String: AppProfile]
    @Published var autoLearned: [String: String]
    @Published var snippets: [String: String]

    init(exceptionsService: ExceptionsService, snippetService: SnippetService = SnippetService()) {
        self.exceptionsService = exceptionsService
        self.snippetService = snippetService
        self.wordExceptions = exceptionsService.wordExceptions
        self.appProfiles = exceptionsService.appProfiles
        self.autoLearned = exceptionsService.autoLearned
        self.snippets = snippetService.snippets
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
}
