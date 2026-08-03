import SwiftUI

struct AboutView: View {
    let onDeleteLocalData: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("О программе")
                    .font(.nfaSans(18, weight: .semibold))
                    .foregroundStyle(Gamma.textPrimary)
                Spacer()
            }
            .padding(22)

            ScrollView {
                VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Gamma.accent.opacity(0.14))
                    Text("QS")
                        .font(.nfaMono(28, weight: .bold))
                        .foregroundStyle(Gamma.accentLight)
                }
                .frame(width: 72, height: 72)

                VStack(spacing: 3) {
                    Text(AppIdentity.displayName)
                        .font(.nfaSans(22, weight: .semibold))
                        .foregroundColor(Gamma.textPrimary)
                    Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.nfaSans(12))
                        .foregroundColor(Gamma.textSecondary)
                }

                Rectangle().fill(Gamma.border).frame(height: 1).padding(.horizontal, 40)

                VStack(spacing: 8) {
                    infoRow("Словарь", "≈714 000 слов (RU + EN)")
                    infoRow("Движок", "BloomFilter + NSSpellChecker")
                    infoRow("Горячие клавиши", "Shift / Double Shift / L+R Shift")
                    infoRow("Аналитика", "Нет (privacy-first)")
                    infoRow("Статус", "Локальная beta")
                    infoRow("Приватность", "100% локально, 0 телеметрии")
                }
                .padding(.horizontal, 24)

                Rectangle().fill(Gamma.border).frame(height: 1).padding(.horizontal, 40)

                    Text("История набора не хранится · текст не покидает Mac")
                    .font(.nfaSans(11))
                    .foregroundColor(Gamma.textMuted)

                    Text(PrivacyService.policyText)
                        .font(.nfaSans(10))
                        .foregroundColor(Gamma.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .nfaGlass(cornerRadius: 10)
                        .padding(.horizontal, 18)

                    Button("Удалить все локальные данные…", action: onDeleteLocalData)
                        .buttonStyle(.borderless)
                        .foregroundColor(Gamma.accentRed)
                        .font(.nfaSans(11, weight: .medium))
                        .padding(.bottom, 14)

                    Spacer()
                }
            }
        }
        .frame(width: 500, height: 560)
        .background(Gamma.bgPrimary)
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.nfaSans(12, weight: .medium))
                .foregroundColor(Gamma.textSecondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.nfaSans(12))
                .foregroundColor(Gamma.textPrimary)
            Spacer()
        }
    }
}
