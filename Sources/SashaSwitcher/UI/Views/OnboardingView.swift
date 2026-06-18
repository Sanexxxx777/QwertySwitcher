import SwiftUI
import AppKit
import Combine

struct OnboardingView: View {
    @StateObject private var watcher = PermissionsWatcher()
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LiquidGlassBackground()
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("ДОБРО  ПОЖАЛОВАТЬ")
                        .font(.nfaSerif(12, weight: .medium))
                        .foregroundColor(Gamma.textSecondary)
                        .tracking(6)
                    Text("SASHA SWITCHER")
                        .font(.nfaSerif(22, weight: .semibold))
                        .tracking(3)
                        .nfaTitleGradient()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 18)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Для работы приложению нужны два разрешения macOS:")
                        .font(.system(size: 13))
                        .foregroundColor(Gamma.textPrimary)

                    permissionRow(
                        title: "Universal Access (Accessibility)",
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
                            .foregroundColor(watcher.hasAll ? Gamma.accentGreen : Gamma.textSecondary)
                        Text(watcher.hasAll
                             ? "Все разрешения на месте — нажми «Далее»"
                             : "Выдай разрешения — кнопка «Далее» активируется сама")
                            .font(.system(size: 11))
                            .foregroundColor(watcher.hasAll ? Gamma.accentGreen : Gamma.textSecondary)
                    }
                    .padding(.top, 4)

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()
                        NFAButton(
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
                .foregroundColor(granted ? Gamma.accentGreen : Gamma.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Gamma.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Gamma.textSecondary)
            }

            Spacer()

            if !granted {
                NFAButton(title: "Открыть", style: .secondary, action: openAction)
            } else {
                Text("ВЫДАНО")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Gamma.accentGreen)
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Gamma.accentGreen.opacity(0.15))
                    )
            }
        }
        .padding(14)
        .nfaGlass(cornerRadius: 10)
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

// MARK: - Shared NFA button (Liquid Glass)

struct NFAButton: View {
    enum Style { case primary, secondary, ghost, disabled }
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
        case .primary:   return Color(hex: 0x0b0b0f)
        case .secondary: return Gamma.accent
        case .ghost:     return Gamma.textPrimary
        case .disabled:  return Gamma.textSecondary
        }
    }
    private var background: some View {
        Group {
            switch style {
            case .primary:
                LinearGradient(colors: [Gamma.accent, Gamma.accentDeep], startPoint: .top, endPoint: .bottom)
                    .opacity(isHovered ? 1.0 : 0.95)
            case .secondary:
                Gamma.accent.opacity(isHovered ? 0.22 : 0.12)
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
        case .secondary: return Gamma.accent.opacity(isHovered ? 0.55 : 0.35)
        case .ghost:     return Color.white.opacity(isHovered ? 0.25 : 0.14)
        case .disabled:  return Color.white.opacity(0.08)
        }
    }
}
