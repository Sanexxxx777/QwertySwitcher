import SwiftUI
import AppKit

// MARK: - Qwerty Switcher design system

struct Gamma {
    static let bgPrimary = Color(hex: 0x111114)
    static let bgCard = Color.white.opacity(0.055)
    static let bgCardHover = Color.white.opacity(0.085)
    static let bgInput = Color.white.opacity(0.075)
    static let bgElevated = Color(hex: 0x1b1b20)

    static let textPrimary = Color(hex: 0xf3eee6)
    static let textSecondary = Color(hex: 0xb0a99f)
    static let textMuted = Color(hex: 0x746e66)

    static let accent = Color(hex: 0xd9905c)
    static let accentDeep = Color(hex: 0xb96e3d)
    static let accentLight = Color(hex: 0xf0b483)
    static let accentGlow = Color(hex: 0xd9905c).opacity(0.16)

    static let accentGreen = Color(hex: 0x67c79b)
    static let accentRed = Color(hex: 0xdf7777)
    static let accentCyan = Color(hex: 0x73bfca)
    static let accentAmber = Color(hex: 0xdfad5d)
    static let accentPurple = Color(hex: 0xbba0d6)

    static let border = Color.white.opacity(0.085)
    static let borderActive = Color.white.opacity(0.16)
    static let borderGlow = accent.opacity(0.28)

    static let bgGradStart = Color(hex: 0x201814)
    static let bgGradMid1 = Color(hex: 0x191719)
    static let bgGradMid2 = Color(hex: 0x15161a)
    static let bgGradMid3 = Color(hex: 0x121318)
    static let bgGradEnd = bgPrimary

    static let titleStops: [Color] = [accentLight, accent]
    static let headerGrad1 = bgGradStart
    static let headerGrad2 = bgGradEnd
}

extension Font {
    static func nfaSerif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Playfair Display", size: size).weight(weight)
    }

    static func nfaSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }

    static func nfaMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }
}

extension View {
    func nfaTitleGradient() -> some View {
        foregroundStyle(
            LinearGradient(colors: Gamma.titleStops, startPoint: .leading, endPoint: .trailing)
        )
    }
}

struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Gamma.bgGradStart, Gamma.bgGradMid1, Gamma.bgGradMid2, Gamma.bgGradEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Gamma.accentGlow, .clear],
                center: UnitPoint(x: 0.16, y: 0.04),
                startRadius: 0,
                endRadius: 330
            )
        }
        .ignoresSafeArea()
    }
}

struct NFAGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Gamma.bgCard
                    LinearGradient(
                        colors: [Color.white.opacity(0.055), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.32)
                    )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Gamma.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func nfaGlass(cornerRadius: CGFloat = 14) -> some View {
        modifier(NFAGlassPanel(cornerRadius: cornerRadius))
    }
}

// MARK: - Main settings

struct MainView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var licenseService = LicenseService.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ZStack {
            LiquidGlassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    masterControl
                    layoutsSection
                    usageSummary
                    shortcutsSection
                    extrasSection
                    footer
                }
                .padding(28)
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 570, idealHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Gamma.accent.opacity(0.14))
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Gamma.accent.opacity(0.28), lineWidth: 1)
                Text("QS")
                    .font(.nfaMono(18, weight: .bold))
                    .foregroundStyle(Gamma.accentLight)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppIdentity.displayName)
                    .font(.nfaSans(24, weight: .semibold))
                    .foregroundStyle(Gamma.textPrimary)
                Text("Локальный переключатель раскладки")
                    .font(.nfaSans(13))
                    .foregroundStyle(Gamma.textSecondary)
            }

            Spacer()

            StatusPill(
                isEnabled: viewModel.isAutoSwitchEnabled,
                health: viewModel.eventTapHealth
            )
        }
    }

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle("Активные раскладки")
            VStack(spacing: 0) {
                LayoutPickerRow(
                    icon: "a.square",
                    title: "Английская",
                    layouts: viewModel.englishLayouts,
                    selection: $viewModel.selectedEnglishLayoutID
                )
                rowDivider
                LayoutPickerRow(
                    icon: "character.book.closed",
                    title: "Русская",
                    layouts: viewModel.russianLayouts,
                    selection: $viewModel.selectedRussianLayoutID
                )
                rowDivider
                SettingToggleRow(
                    icon: "app.badge.checkmark",
                    title: "Запоминать раскладку для приложений",
                    subtitle: "выключено по умолчанию; хранится только bundle ID",
                    isOn: $viewModel.isPerAppLayoutEnabled
                )
            }
            .nfaGlass(cornerRadius: 14)
        }
    }

    private var masterControl: some View {
        Toggle(isOn: $viewModel.isAutoSwitchEnabled) {
            HStack(spacing: 13) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(viewModel.isAutoSwitchEnabled ? Gamma.accent : Gamma.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Gamma.accent.opacity(viewModel.isAutoSwitchEnabled ? 0.13 : 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Автопереключение")
                        .font(.nfaSans(15, weight: .semibold))
                        .foregroundStyle(Gamma.textPrimary)
                    Text("Определяет язык и исправляет раскладку во время набора")
                        .font(.nfaSans(12))
                        .foregroundStyle(Gamma.textSecondary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Gamma.accent)
        .padding(16)
        .nfaGlass(cornerRadius: 14)
        .accessibilityHint("Включает или отключает автоматическое исправление раскладки")
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle("За всё время")
            HStack(spacing: 0) {
                UsageMetric(value: viewModel.autoSwitchCount, label: "исправлений")
                metricDivider
                UsageMetric(value: viewModel.shiftSwitchCount, label: "смен раскладки")
                metricDivider
                UsageMetric(value: viewModel.doubleShiftCount, label: "конвертаций слова")
            }
            .padding(.vertical, 14)
            .nfaGlass(cornerRadius: 12)
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Gamma.border)
            .frame(width: 1, height: 38)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle("Горячие клавиши")
            VStack(spacing: 0) {
                SettingToggleRow(
                    icon: "arrow.up",
                    title: "Single Shift",
                    subtitle: "сменить текущую раскладку",
                    isOn: $viewModel.isSingleShiftEnabled
                )
                rowDivider
                SettingToggleRow(
                    icon: "arrow.up.arrow.down",
                    title: "Double Shift",
                    subtitle: "переключить последнее набранное слово",
                    isOn: $viewModel.isDoubleShiftEnabled
                )
                rowDivider
                SettingToggleRow(
                    icon: "capslock",
                    title: "Caps Lock",
                    subtitle: "сменить раскладку, не включая верхний регистр",
                    isOn: $viewModel.isCapsLockSwitchEnabled
                )
                rowDivider
                SettingToggleRow(
                    icon: "arrow.left.arrow.right",
                    title: "Left Shift + Right Shift",
                    subtitle: "быстро включить или выключить автопереключение",
                    isOn: $viewModel.isSplitShiftEnabled
                )
                rowDivider
                SettingToggleRow(
                    icon: "doc.on.clipboard",
                    title: "Command + Shift + V",
                    subtitle: "вставить текст без форматирования",
                    isOn: $viewModel.isPasteNoFormatEnabled
                )
            }
            .nfaGlass(cornerRadius: 14)
        }
    }

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle("Дополнительно")
            VStack(spacing: 0) {
                SettingToggleRow(
                    icon: "textformat",
                    title: "Ёфикатор",
                    subtitle: "добавлять букву ё по правилам языка",
                    isOn: $viewModel.isYoficatorEnabled
                )
                rowDivider
                SettingToggleRow(
                    icon: "speaker.wave.2",
                    title: "Звуки",
                    subtitle: "подтверждать исправления и смену раскладки",
                    isOn: $viewModel.isSoundEnabled
                )
            }
            .nfaGlass(cornerRadius: 14)
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Gamma.border)
            .frame(height: 1)
            .padding(.leading, 55)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.onOpenExceptions?()
            } label: {
                Label("Исключения", systemImage: "text.badge.minus")
            }

            Button {
                viewModel.onOpenAbout?()
            } label: {
                Label("О программе", systemImage: "info.circle")
            }

            Button {
                viewModel.onOpenLicense?()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(licenseService.isEntitled ? Gamma.accentGreen : Gamma.accentAmber)
                        .frame(width: 6, height: 6)
                    Text(licenseService.statusSummary)
                }
            }

            Spacer()

            Text("Версия \(appVersion)")
                .font(.nfaMono(11))
                .foregroundStyle(Gamma.textMuted)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Gamma.textSecondary)
        .font(.nfaSans(12, weight: .medium))
    }
}

private struct StatusPill: View {
    let isEnabled: Bool
    let health: EventTapHealth

    private var label: String {
        guard health == .running else { return health.title }
        return isEnabled ? "Работает" : "На паузе"
    }

    private var color: Color {
        if health == .running { return isEnabled ? Gamma.accentGreen : Gamma.textMuted }
        if health == .secureInput { return Gamma.accentAmber }
        return Gamma.accentRed
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.nfaSans(11, weight: .medium))
        }
        .foregroundStyle(health == .running && isEnabled ? Gamma.textPrimary : Gamma.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Gamma.bgCard)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Gamma.border, lineWidth: 1))
        .accessibilityLabel(label)
    }
}

private struct LayoutPickerRow: View {
    let icon: String
    let title: String
    let layouts: [KeyboardLayout]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Gamma.accent)
                .frame(width: 28)
            Text(title)
                .font(.nfaSans(13, weight: .medium))
                .foregroundStyle(Gamma.textPrimary)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(layouts, id: \.id) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.nfaSans(10, weight: .semibold))
            .tracking(1.15)
            .foregroundStyle(Gamma.textMuted)
    }
}

private struct UsageMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted())
                .font(.nfaMono(20, weight: .semibold))
                .foregroundStyle(Gamma.textPrimary)
            Text(label)
                .font(.nfaSans(11))
                .foregroundStyle(Gamma.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct SettingToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Gamma.accent : Gamma.textMuted)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.nfaSans(13, weight: .medium))
                        .foregroundStyle(Gamma.textPrimary)
                    Text(subtitle)
                        .font(.nfaSans(11))
                        .foregroundStyle(Gamma.textSecondary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Gamma.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityHint(subtitle)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
