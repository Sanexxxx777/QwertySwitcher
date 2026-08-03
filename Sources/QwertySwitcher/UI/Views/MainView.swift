import SwiftUI
import AppKit

// MARK: - Qwerty Switcher design system
//
// A quiet, native-feeling system utility (Bartender / CleanShot / Raycast register),
// not a branded dashboard skin. Neutral graphite/paper surfaces, one functional accent
// (macOS system blue — chosen so the app reads as *part of* macOS, not painted on top
// of it), SF Pro throughout. Colors/fonts are never hardcoded in view bodies — every
// view reads `@Environment(\.appTheme)` and the concrete palette flips live between
// `.dark`/`.light` (or follows the OS) via the root modifier below, applied once at the
// point where each window's NSHostingView is created — NOT in `body`, otherwise
// `@Environment` inside the view tree sees a stale value and the light theme breaks.

enum ThemePreference: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "Система"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
}

extension Notification.Name {
    static let themePreferenceChanged = Notification.Name(AppIdentity.keyPrefix + "themePreferenceChanged")
}

struct AppTheme {
    let isDark: Bool

    let bgPrimary: Color
    let bgCard: Color
    let bgCardHover: Color
    let bgInput: Color

    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color

    let accent: Color
    let accentDeep: Color
    let accentLight: Color

    let accentGreen: Color
    let accentAmber: Color
    let accentRed: Color

    let border: Color
    let borderActive: Color

    /// Muted palette tone for the OFF state of toggles — never plain gray.
    let toggleOffTint: Color

    static func resolve(_ scheme: ColorScheme) -> AppTheme {
        scheme == .light ? .light : .dark
    }

    static let dark = AppTheme(
        isDark: true,
        bgPrimary: Color(hex: 0x1e1e20),
        bgCard: Color.white.opacity(0.045),
        bgCardHover: Color.white.opacity(0.075),
        bgInput: Color.white.opacity(0.08),
        textPrimary: Color(hex: 0xf0f0f2),
        textSecondary: Color(hex: 0x98989d),
        textMuted: Color(hex: 0x67676c),
        accent: Color(hex: 0x0a84ff),
        accentDeep: Color(hex: 0x0868cc),
        accentLight: Color(hex: 0x64b5ff),
        accentGreen: Color(hex: 0x30d158),
        accentAmber: Color(hex: 0xff9f0a),
        accentRed: Color(hex: 0xff453a),
        border: Color.white.opacity(0.09),
        borderActive: Color.white.opacity(0.17),
        toggleOffTint: Color(hex: 0x0a84ff).opacity(0.32)
    )

    static let light = AppTheme(
        isDark: false,
        bgPrimary: Color(hex: 0xf2f2f4),
        bgCard: Color.white,
        bgCardHover: Color(hex: 0xf1f1f3),
        bgInput: Color(hex: 0xf7f7f8),
        textPrimary: Color(hex: 0x1d1d1f),
        textSecondary: Color(hex: 0x6e6e73),
        textMuted: Color(hex: 0x9a9a9e),
        accent: Color(hex: 0x007aff),
        accentDeep: Color(hex: 0x0059b3),
        accentLight: Color(hex: 0x3d9bff),
        accentGreen: Color(hex: 0x34c759),
        accentAmber: Color(hex: 0xff9500),
        accentRed: Color(hex: 0xff3b30),
        border: Color.black.opacity(0.08),
        borderActive: Color.black.opacity(0.15),
        // Was 0.16 in the first pass — measured too pale against the light card fill,
        // so raised the floor here.
        toggleOffTint: Color(hex: 0x007aff).opacity(0.28)
    )
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.dark
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Apply once at the root of every window. Reads the user's `ThemePreference` from
/// `PreferencesService` and reacts live to `.themePreferenceChanged` (posted whenever any
/// window changes the setting) — no restart, no per-window plumbing needed.
private struct ThemedRootModifier: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @State private var preference: ThemePreference = PreferencesService().themePreference

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preference.colorScheme)
            .environment(\.appTheme, AppTheme.resolve(preference.colorScheme ?? systemScheme))
            .onReceive(NotificationCenter.default.publisher(for: .themePreferenceChanged)) { _ in
                preference = PreferencesService().themePreference
            }
    }
}

extension View {
    // Name kept stable across the call sites in AppDelegate.swift/StatusBarController.swift —
    // only the internal implementation was redesigned.
    func gammaThemedRoot() -> some View { modifier(ThemedRootModifier()) }
}

extension Font {
    static func appText(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func appMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Flat window background — no blur, no texture, no glow. A settings window's canvas
/// should be quiet; the accent color does the one job of drawing the eye.
struct AppBackground: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        theme.bgPrimary.ignoresSafeArea()
    }
}

/// A grouped-list style card: flat tinted fill + hairline border, matching how native
/// macOS Settings groups rows — no blur material, no gradient sheen.
struct SettingsCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(theme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func settingsCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius))
    }
}

/// Pill switch with a palette-tinted OFF track (never plain gray) — replaces the native
/// `.switch` toggle style so both states stay on-brand in both themes.
struct PillToggleStyle: ToggleStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? theme.accent : theme.toggleOffTint)
                .frame(width: 34, height: 20)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .padding(3)
                        .offset(x: configuration.isOn ? 7 : -7)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                )
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

extension ToggleStyle where Self == PillToggleStyle {
    static var pill: PillToggleStyle { PillToggleStyle() }
}

// MARK: - Main settings

private enum MainTab: String, CaseIterable, Identifiable {
    case status, shortcuts, more
    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: return "Статус"
        case .shortcuts: return "Клавиши"
        case .more: return "Ещё"
        }
    }
}

struct MainView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var licenseService = LicenseService.shared
    @Environment(\.appTheme) private var theme
    @State private var selectedTab: MainTab = .status

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Picker("", selection: $selectedTab) {
                ForEach(MainTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Group {
                switch selectedTab {
                case .status: statusTab
                case .shortcuts: shortcutsTab
                case .more: moreTab
                }
            }
            .padding(.horizontal, 20)

            footer
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 18)
        }
        .background(AppBackground())
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header — status word + the one toggle that matters most, always visible.

    private var heroWord: String {
        if viewModel.eventTapHealth == .running {
            return viewModel.isAutoSwitchEnabled ? "Работает" : "На паузе"
        }
        return viewModel.eventTapHealth.title
    }

    private var heroColor: Color {
        switch viewModel.eventTapHealth {
        case .running:
            return viewModel.isAutoSwitchEnabled ? theme.accentGreen : theme.textSecondary
        case .secureInput: return theme.accentAmber
        case .starting: return theme.textSecondary
        case .missingPermissions, .unavailable, .stopped: return theme.accentRed
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(heroColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: heroColor.opacity(0.45), radius: 2.5)
                    Text(heroWord)
                        .font(.appText(19, weight: .semibold))
                        .foregroundStyle(heroColor)
                }
                Text("Определяет язык и исправляет раскладку во время набора")
                    .font(.appText(11))
                    .foregroundStyle(theme.textSecondary)
            }
            autoSwitchRow
        }
    }

    private var autoSwitchRow: some View {
        Toggle(isOn: $viewModel.isAutoSwitchEnabled) {
            HStack(spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(viewModel.isAutoSwitchEnabled ? theme.accent : theme.textMuted)
                    .frame(width: 20)
                Text("Автопереключение")
                    .font(.appText(13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .toggleStyle(.pill)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .settingsCard()
        .accessibilityHint("Включает или отключает автоматическое исправление раскладки")
    }

    // MARK: Tab 1 — Статус: stats + active layouts, everything visible with no scroll.

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            statsStrip
            layoutsSection
        }
        .padding(.bottom, 4)
    }

    private var statsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("За всё время")
            HStack(spacing: 0) {
                UsageMetric(value: viewModel.autoSwitchCount, label: "исправлений")
                metricDivider
                UsageMetric(value: viewModel.shiftSwitchCount, label: "смен раскладки")
                metricDivider
                UsageMetric(value: viewModel.doubleShiftCount, label: "конвертаций слова")
            }
            .padding(.vertical, 12)
            .settingsCard()
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 32)
    }

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .settingsCard()
        }
    }

    // MARK: Tab 2 — Клавиши

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .settingsCard()
        }
        .padding(.bottom, 4)
    }

    // MARK: Tab 3 — Ещё

    private var moreTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Дополнительно")
            VStack(spacing: 0) {
                SettingToggleRow(
                    icon: "bolt",
                    title: "Мгновенная коррекция",
                    subtitle: "исправлять слово прямо во время набора, не дожидаясь пробела",
                    isOn: $viewModel.isInstantCorrectionEnabled
                )
                rowDivider
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
                rowDivider
                themeRow
            }
            .settingsCard()
        }
        .padding(.bottom, 4)
    }

    private var themeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textMuted)
                .frame(width: 22)
            Text("Тема")
                .font(.appText(13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Picker("Тема", selection: $viewModel.themePreference) {
                ForEach(ThemePreference.allCases, id: \.self) { pref in
                    Text(pref.label).tag(pref)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            FooterButton(icon: "text.badge.minus", title: "Исключения") {
                viewModel.onOpenExceptions?()
            }
            FooterButton(icon: "info.circle", title: "О программе") {
                viewModel.onOpenAbout?()
            }
            LicenseBadge(color: licenseBadgeColor, text: licenseService.statusSummary) {
                viewModel.onOpenLicense?()
            }

            Spacer()

            Text("Версия \(appVersion)")
                .font(.appMono(11))
                .foregroundStyle(theme.textMuted)
                .monospacedDigit()
        }
    }

    /// Trial → amber, active subscription → green, expired → red (все приглушённые).
    private var licenseBadgeColor: Color {
        guard licenseService.isEntitled else { return theme.accentRed }
        let isTrial = licenseService.currentPayload?.plan == "trial" || licenseService.isProvisionalTrial
        return isTrial ? theme.accentAmber : theme.accentGreen
    }
}

private struct LayoutPickerRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let layouts: [KeyboardLayout]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            Text(title)
                .font(.appText(13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(layouts, id: \.id) { layout in
                    Text(layout.name).tag(layout.id)
                }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SectionTitle: View {
    @Environment(\.appTheme) private var theme
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.appText(10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(theme.textMuted)
    }
}

/// Ghost footer action button — subtle hover highlight, 0.15s ease-out.
private struct FooterButton: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appText(11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isHovered ? theme.bgCardHover : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// License status as a muted colored pill (amber=trial / green=active / red=expired).
private struct LicenseBadge: View {
    let color: Color
    let text: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text)
                    .font(.appText(11, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(isHovered ? 0.18 : 0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

private struct UsageMetric: View {
    @Environment(\.appTheme) private var theme
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted())
                .font(.appMono(18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.appText(10))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct SettingToggleRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? theme.accent : theme.textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.appText(12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.appText(10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .toggleStyle(.pill)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
