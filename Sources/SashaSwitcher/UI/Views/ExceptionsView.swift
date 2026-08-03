import SwiftUI

struct ExceptionsView: View {
    @ObservedObject var viewModel: ExceptionsViewModel
    @State private var newWord = ""
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Исключения")
                        .font(.nfaSans(19, weight: .semibold))
                        .foregroundColor(Gamma.textPrimary)
                    Text("Что Qwerty Switch не должен исправлять")
                        .font(.nfaSans(11))
                        .foregroundColor(Gamma.textSecondary)
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
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .colorMultiply(Gamma.accent)

            // Content
            Group {
                switch selectedTab {
                case 0: wordExceptionsTab
                case 1: appExceptionsTab
                case 2: autoLearnedTab
                default: EmptyView()
                }
            }
        }
        .frame(width: 460, height: 440)
        .background(Gamma.bgPrimary)
        .preferredColorScheme(.dark)
    }

    // MARK: - Word Exceptions

    private var wordExceptionsTab: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Добавить слово...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .foregroundColor(Gamma.textPrimary)
                    .onSubmit { addWord() }

                Button("Добавить") { addWord() }
                    .buttonStyle(.borderedProminent)
                    .tint(Gamma.accent)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)

            List {
                ForEach(viewModel.wordExceptions.sorted(), id: \.self) { word in
                    HStack {
                        Text(word)
                            .foregroundColor(Gamma.textPrimary)
                        Spacer()
                        Button(action: { withAnimation { viewModel.removeWord(word) } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Gamma.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить слово \(word)")
                    }
                    .listRowBackground(Gamma.bgCard)
                }
            }
            .scrollContentBackground(.hidden)

            Text("\(viewModel.wordExceptions.count) слов в исключениях")
                .font(.caption)
                .foregroundColor(Gamma.textSecondary)
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
                Text("Автопереключение отключено для:")
                    .font(.caption)
                    .foregroundColor(Gamma.textSecondary)
                Spacer()
                Button("+ Текущее приложение") { withAnimation { viewModel.addCurrentApp() } }
                    .font(.caption)
                    .foregroundColor(Gamma.accent)
            }
            .padding(.horizontal, 16)

            List {
                ForEach(viewModel.appExceptions.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Gamma.textPrimary)
                        Spacer()
                        Button(action: { withAnimation { viewModel.removeApp(bundleID) } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Gamma.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить приложение \(bundleID)")
                    }
                    .listRowBackground(Gamma.bgCard)
                }
            }
            .scrollContentBackground(.hidden)

            Text("\(viewModel.appExceptions.count) приложений в исключениях")
                .font(.caption)
                .foregroundColor(Gamma.textSecondary)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Auto-Learned

    private var autoLearnedTab: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Запомненные исправления:")
                    .font(.caption)
                    .foregroundColor(Gamma.textSecondary)
                Spacer()
                if !viewModel.autoLearned.isEmpty {
                    Button("Очистить") { withAnimation { viewModel.clearAutoLearned() } }
                        .font(.caption)
                        .foregroundColor(Gamma.accentDeep)
                }
            }
            .padding(.horizontal, 16)

            if viewModel.autoLearned.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 32))
                        .foregroundColor(Gamma.textSecondary.opacity(0.3))
                    Text("Пока пусто")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Gamma.textSecondary)
                    Text("Исключение появится после полного удаления\nисправления и точного повторного ввода")
                        .font(.system(size: 12))
                        .foregroundColor(Gamma.textSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List {
                    ForEach(Array(viewModel.autoLearned.keys.sorted()), id: \.self) { key in
                        HStack {
                            Text(key)
                                .foregroundColor(Gamma.textPrimary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(Gamma.textSecondary.opacity(0.5))
                            Text(viewModel.autoLearned[key] ?? "")
                                .foregroundColor(Gamma.textSecondary)
                            Spacer()
                            Button(action: { withAnimation { viewModel.removeAutoLearned(key) } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Gamma.textSecondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Удалить запомнённое исправление \(key)")
                        }
                        .listRowBackground(Gamma.bgCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

final class ExceptionsViewModel: ObservableObject {
    private let exceptionsService: ExceptionsService

    @Published var wordExceptions: Set<String>
    @Published var appExceptions: Set<String>
    @Published var autoLearned: [String: String]

    init(exceptionsService: ExceptionsService) {
        self.exceptionsService = exceptionsService
        self.wordExceptions = exceptionsService.wordExceptions
        self.appExceptions = exceptionsService.appExceptions
        self.autoLearned = exceptionsService.autoLearned
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
            appExceptions = exceptionsService.appExceptions
        }
    }

    func removeApp(_ bundleID: String) {
        exceptionsService.removeAppException(bundleID)
        appExceptions = exceptionsService.appExceptions
    }

    func clearAutoLearned() {
        exceptionsService.autoLearned = [:]
        autoLearned = [:]
    }

    func removeAutoLearned(_ key: String) {
        exceptionsService.removeAutoLearned(key)
        autoLearned = exceptionsService.autoLearned
    }
}
