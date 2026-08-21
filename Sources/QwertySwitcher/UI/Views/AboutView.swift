import SwiftUI

struct AboutView: View {
    let onDeleteLocalData: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .frame(width: 500, height: 560)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text("О программе")
                    .font(.appText(18, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(22)

            ScrollView {
                VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                    Text("QS")
                        .font(.appMono(28, weight: .bold))
                        .foregroundStyle(theme.accentLight)
                }
                .frame(width: 72, height: 72)

                VStack(spacing: 3) {
                    Text(AppIdentity.displayName)
                        .font(.appText(22, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.appText(12))
                        .foregroundColor(theme.textSecondary)
                }

                Rectangle().fill(theme.border).frame(height: 1).padding(.horizontal, 40)

                VStack(spacing: 8) {
                    infoRow("Словарь", "≈714 000 слов (RU + EN)")
                    infoRow("Движок", "BloomFilter + NSSpellChecker")
                    infoRow("Горячие клавиши", "Shift / Double Shift / L+R Shift")
                    infoRow("Аналитика", "Нет (privacy-first)")
                    infoRow("Статус", "Локальная beta")
                    infoRow("Приватность", "Ввод — локально, 0 телеметрии")
                }
                .padding(.horizontal, 24)

                Rectangle().fill(theme.border).frame(height: 1).padding(.horizontal, 40)

                    Text("Весь ввод обрабатывается локально и никогда не покидает Mac.\nЛицензионная проверка отправляет идентификатор Mac и версию приложения.")
                    .font(.appText(11))
                    .foregroundColor(theme.textMuted)
                    .multilineTextAlignment(.center)

                    Text(PrivacyService.policyText)
                        .font(.appText(10))
                        .foregroundColor(theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .settingsCard(cornerRadius: 10)
                        .padding(.horizontal, 18)

                    Button("Удалить все локальные данные…", action: onDeleteLocalData)
                        .buttonStyle(.borderless)
                        .foregroundColor(theme.accentRed)
                        .font(.appText(11, weight: .medium))
                        .padding(.bottom, 14)

                    Spacer()
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.appText(12, weight: .medium))
                .foregroundColor(theme.textSecondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.appText(12))
                .foregroundColor(theme.textPrimary)
            Spacer()
        }
    }
}
