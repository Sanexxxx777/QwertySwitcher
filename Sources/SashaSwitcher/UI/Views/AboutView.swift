import SwiftUI

struct AboutView: View {
    @State private var logoScale = 0.8
    @State private var logoOpacity = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack {
                LinearGradient(
                    colors: [Gamma.headerGrad1, Gamma.headerGrad2],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Text("О ПРОГРАММЕ")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundColor(Gamma.textPrimary)
                    .tracking(3)
            }
            .frame(height: 60)

            VStack(spacing: 16) {
                Spacer()

                // Animated logo
                Text("SS")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                    .foregroundColor(Gamma.accent)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .onAppear {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.1)) {
                            logoScale = 1.0
                            logoOpacity = 1.0
                        }
                    }

                Text("Sasha Switcher")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundColor(Gamma.textPrimary)

                Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 13))
                    .foregroundColor(Gamma.textSecondary)

                Rectangle().fill(Gamma.border).frame(height: 1).padding(.horizontal, 40)

                VStack(spacing: 8) {
                    infoRow("Словарь", "714,100 слов (RU + EN)")
                    infoRow("Движок", "BloomFilter + NSSpellChecker")
                    infoRow("Горячие клавиши", "Shift / Double Shift / L+R Shift")
                    infoRow("Аналитика", "Нет (privacy-first)")
                    infoRow("Стоимость", "Бесплатно навсегда")
                    infoRow("Приватность", "100% локально, 0 телеметрии")
                }
                .padding(.horizontal, 24)

                Rectangle().fill(Gamma.border).frame(height: 1).padding(.horizontal, 40)

                Spacer()
            }
        }
        .frame(width: 400, height: 380)
        .background(Gamma.bgPrimary)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Gamma.textSecondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(Gamma.textPrimary)
            Spacer()
        }
    }
}
