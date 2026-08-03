import SwiftUI
import AppKit
import Combine

struct OnboardingView: View {
    @StateObject private var watcher = PermissionsWatcher()
    @Environment(\.appTheme) private var theme
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accent.opacity(0.14))
                        Text("QS")
                            .font(.appMono(15, weight: .bold))
                            .foregroundStyle(theme.accentLight)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Настройка Qwerty Switcher")
                            .font(.appText(19, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text("Два системных разрешения — текст остаётся на Mac")
                            .font(.appText(11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Разрешения macOS")
                        .font(.appText(12, weight: .semibold))
                        .foregroundColor(theme.textPrimary)

                    permissionRow(
                        title: "Универсальный доступ",
                        subtitle: "для перехвата нажатий и исправления текста",
                        granted: watcher.hasAccessibility,
                        openAction: {
                            let perms = PermissionsService()
                            perms.requestAccessibility()
                            perms.openAccessibilitySettings()
                        }
                    )

                    permissionRow(
                        title: "Input Monitoring",
                        subtitle: "для чтения кодов клавиш",
                        granted: watcher.hasInputMonitoring,
                        openAction: {
                            let perms = PermissionsService()
                            perms.requestInputMonitoring()
                            perms.openInputMonitoringSettings()
                        }
                    )

                    HStack(spacing: 8) {
                        Image(systemName: watcher.hasAll ? "checkmark.seal.fill" : "info.circle")
                            .foregroundColor(watcher.hasAll ? theme.accentGreen : theme.textSecondary)
                        Text(watcher.hasAll
                             ? "Все разрешения на месте — нажми «Далее»"
                             : "Выдай разрешения — кнопка «Далее» активируется сама")
                            .font(.appText(11))
                            .foregroundColor(watcher.hasAll ? theme.accentGreen : theme.textSecondary)
                    }
                    .padding(.top, 4)

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()
                        AppButton(
                            title: "Далее",
                            style: watcher.hasAll ? .primary : .disabled,
                            action: onContinue
                        )
                        .disabled(!watcher.hasAll)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 480, height: 380)
        .onAppear { watcher.startPolling() }
        .onDisappear { watcher.stopPolling() }
    }

    private func permissionRow(title: String, subtitle: String, granted: Bool, openAction: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(granted ? theme.accentGreen : theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appText(13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(subtitle)
                    .font(.appText(11))
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            if !granted {
                AppButton(title: "Открыть", style: .secondary, action: openAction)
            } else {
                Text("ВЫДАНО")
                    .font(.appText(9, weight: .bold))
                    .foregroundColor(theme.accentGreen)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(theme.accentGreen.opacity(0.15))
                    )
            }
        }
        .padding(14)
        .settingsCard(cornerRadius: 10)
    }
}

// MARK: - Permissions Watcher (polls TCC every second while window visible)

final class PermissionsWatcher: ObservableObject {
    @Published var hasAccessibility: Bool = false
    @Published var hasInputMonitoring: Bool = false
    @Published var isPolling: Bool = false

    private var timer: Timer?
    private let service = PermissionsService()

    var hasAll: Bool { hasAccessibility && hasInputMonitoring }

    func startPolling() {
        refresh()
        isPolling = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let a = service.hasAccessibility
        let i = service.hasInputMonitoring
        if a != hasAccessibility { hasAccessibility = a }
        if i != hasInputMonitoring { hasInputMonitoring = i }
    }
}

// MARK: - Shared button style

struct AppButton: View {
    enum Style { case primary, secondary, ghost, disabled }
    @Environment(\.appTheme) private var theme
    let title: String
    let style: Style
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(style == .disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 && style != .disabled }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var foreground: Color {
        switch style {
        case .primary:   return .white
        case .secondary: return theme.accent
        case .ghost:     return theme.textPrimary
        case .disabled:  return theme.textSecondary
        }
    }
    private var background: some View {
        Group {
            switch style {
            case .primary:
                LinearGradient(colors: [theme.accent, theme.accentDeep], startPoint: .top, endPoint: .bottom)
                    .opacity(isHovered ? 1.0 : 0.95)
            case .secondary:
                theme.accent.opacity(isHovered ? 0.22 : 0.12)
            case .ghost:
                Color.white.opacity(isHovered ? 0.1 : 0.05)
            case .disabled:
                Color.white.opacity(0.04)
            }
        }
    }
    private var borderColor: Color {
        switch style {
        case .primary:   return .clear
        case .secondary: return theme.accent.opacity(isHovered ? 0.55 : 0.35)
        case .ghost:     return Color.white.opacity(isHovered ? 0.25 : 0.14)
        case .disabled:  return Color.white.opacity(0.08)
        }
    }
}
