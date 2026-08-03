import SwiftUI
import AppKit

struct LicenseView: View {
    @ObservedObject private var licenseService = LicenseService.shared
    @State private var keyInput: String = ""
    @State private var isActivating = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Лицензия")
                    .font(.nfaSans(18, weight: .semibold))
                    .foregroundStyle(Gamma.textPrimary)
                Spacer()
            }
            .padding(22)

            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    activationCard
                    linksRow
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .frame(width: 440, height: 480)
        .background(Gamma.bgPrimary)
        .preferredColorScheme(.dark)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(licenseService.isEntitled ? Gamma.accentGreen : Gamma.accentRed)
                    .frame(width: 8, height: 8)
                Text(licenseService.statusHeadline)
                    .font(.nfaSans(14, weight: .semibold))
                    .foregroundStyle(Gamma.textPrimary)
            }
            if licenseService.isEntitled {
                Text("Осталось дней: \(licenseService.daysRemaining)")
                    .font(.nfaSans(12))
                    .foregroundStyle(Gamma.textSecondary)
            } else {
                Text("Автозамена и конвертация слов отключены до активации ключа")
                    .font(.nfaSans(12))
                    .foregroundStyle(Gamma.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nfaGlass(cornerRadius: 14)
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("АКТИВИРОВАТЬ КЛЮЧ")
                .font(.nfaSans(10, weight: .semibold))
                .tracking(1.15)
                .foregroundStyle(Gamma.textMuted)

            TextField("QSW-XXXX-XXXX-XXXX", text: Binding(
                get: { keyInput },
                set: { keyInput = Self.autoFormat($0) }
            ))
            .textFieldStyle(.plain)
            .font(.nfaMono(13, weight: .medium))
            .foregroundStyle(Gamma.textPrimary)
            .padding(10)
            .background(Gamma.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Gamma.border, lineWidth: 1)
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.nfaSans(11))
                    .foregroundStyle(Gamma.accentRed)
            }
            if let successMessage {
                Text(successMessage)
                    .font(.nfaSans(11))
                    .foregroundStyle(Gamma.accentGreen)
            }

            Button {
                activate()
            } label: {
                Text(isActivating ? "Проверка…" : "Активировать")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Gamma.accent)
            .disabled(isActivating || keyInput.count < 15)
        }
        .padding(16)
        .nfaGlass(cornerRadius: 14)
    }

    private var linksRow: some View {
        HStack(spacing: 18) {
            Button("Купить ключ") {
                NSWorkspace.shared.open(URL(string: "https://shulgin.is-a.dev/store/#apps")!)
            }
            Button("Написать в Telegram") {
                NSWorkspace.shared.open(URL(string: "https://t.me/Aleksandr_NFA")!)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Gamma.accent)
        .font(.nfaSans(12, weight: .medium))
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
