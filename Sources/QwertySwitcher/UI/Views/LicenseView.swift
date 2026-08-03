import SwiftUI
import AppKit

struct LicenseView: View {
    @ObservedObject private var licenseService = LicenseService.shared
    @Environment(\.appTheme) private var theme
    @State private var keyInput: String = ""
    @State private var isActivating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    activationCard
                    linksRow
                }
                .padding(20)
            }
        }
        .frame(width: 400, height: 420)
    }

    // MARK: Hero — short status word, same semantics as the footer badge in MainView.

    private var heroWord: String {
        guard licenseService.currentPayload != nil else { return "Не активирована" }
        if !licenseService.isEntitled { return "Истекла" }
        if licenseService.currentPayload?.plan == "trial" || licenseService.isProvisionalTrial {
            return "Пробный период"
        }
        return "Подписка активна"
    }

    private var heroColor: Color {
        guard licenseService.isEntitled else { return theme.accentRed }
        let isTrial = licenseService.currentPayload?.plan == "trial" || licenseService.isProvisionalTrial
        return isTrial ? theme.accentAmber : theme.accentGreen
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heroWord)
                .font(.appText(22, weight: .semibold))
                .foregroundStyle(heroColor)

            if licenseService.isEntitled {
                Text("Осталось дней: \(licenseService.daysRemaining)")
                    .font(.appText(11))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            } else {
                Text("Автозамена и конвертация слов отключены до активации ключа")
                    .font(.appText(11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("АКТИВИРОВАТЬ КЛЮЧ")
                .font(.appText(10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(theme.textMuted)

            TextField("QSW-XXXX-XXXX-XXXX", text: Binding(
                get: { keyInput },
                set: { keyInput = Self.autoFormat($0) }
            ))
            .textFieldStyle(.plain)
            .font(.appMono(13, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .padding(10)
            .background(theme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.appText(11))
                    .foregroundStyle(theme.accentRed)
            }
            if let successMessage {
                Text(successMessage)
                    .font(.appText(11))
                    .foregroundStyle(theme.accentGreen)
            }

            PrimaryButton(
                title: isActivating ? "Проверка…" : "Активировать",
                isDisabled: isActivating || keyInput.count < 15,
                action: activate
            )
        }
        .padding(14)
        .settingsCard()
    }

    private var linksRow: some View {
        HStack(spacing: 16) {
            Button("Купить ключ") {
                NSWorkspace.shared.open(URL(string: "https://shulgin.is-a.dev/store/#apps")!)
            }
            Button("Написать в Telegram") {
                NSWorkspace.shared.open(URL(string: "https://t.me/Aleksandr_NFA")!)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.accent)
        .font(.appText(11, weight: .medium))
    }

    private func activate() {
        errorMessage = nil
        successMessage = nil
        isActivating = true
        LicenseService.shared.activate(key: keyInput) { outcome in
            isActivating = false
            switch outcome {
            case .success:
                successMessage = "Лицензия активирована"
            case .invalidKey:
                errorMessage = "Неверный ключ"
            case .keyUsed:
                errorMessage = "Ключ уже использован"
            case .network:
                errorMessage = "Нет сети — проверьте подключение"
            case .serverError:
                errorMessage = "Не удалось проверить ключ — попробуйте позже"
            }
        }
    }

    /// Uppercase QSW-XXXX-XXXX-XXXX auto-format as the user types.
    static func autoFormat(_ input: String) -> String {
        let cleaned = input.uppercased().filter { $0.isLetter || $0.isNumber }
        let groupSizes = [3, 4, 4, 4]
        var groups: [String] = []
        var index = cleaned.startIndex
        for size in groupSizes {
            guard index < cleaned.endIndex else { break }
            let end = cleaned.index(index, offsetBy: size, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            groups.append(String(cleaned[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }
}

/// Primary CTA button — accent fill, pill shape, hover brighten.
private struct PrimaryButton: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appText(13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: [theme.accent, theme.accentDeep], startPoint: .top, endPoint: .bottom)
                        .opacity(isHovered && !isDisabled ? 1.0 : 0.92)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.45 : 1.0)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
