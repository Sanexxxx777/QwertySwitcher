import SwiftUI
import AppKit

// MARK: - Qwerty Switcher design system
//
// A quiet, native-feeling system utility (Bartender / CleanShot / Raycast register),
// not a branded dashboard skin. Base surfaces and text below are AppKit *semantic*
// colors (`NSColor.labelColor`, `.controlAccentColor`, `.separatorColor`, ...; see
// Apple HIG "Color" → macOS platform table) rather than hand-picked hex — they resolve
// dynamically against the window's current appearance, so they're automatically correct
// in both themes, in Increase Contrast, and — for `accent` specifically — follow the
// user's own System Settings › Appearance › Accent color instead of a color we baked
// in. Hardcoded hex stays reserved for the app's own decorative layer (the status/stats
// motifs further down), never for base surfaces or text. SF Pro throughout. Colors/fonts
// are never hardcoded in view bodies — every view reads `@Environment(\.appTheme)` and
// the concrete palette flips live between `.dark`/`.light` (or follows the OS) via the
// root modifier below, applied once at the point where each window's NSHostingView is
// created — NOT in `body`, otherwise `@Environment` inside the view tree sees a stale
// value and the light theme breaks.

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
    /// Card outline. Denser than `border`, which stays for hairlines inside a
    /// card — the contrast between the two is what groups rows.
    let borderCard: Color
    let borderActive: Color

    /// Recessed well behind the selected-tab "keycap". Selection reads by
    /// elevation instead of a tinted rectangle: the thumb uses `bgCard`, this
    /// sits under it, and the two only separate if this tone is distinct from
    /// BOTH the window background and the card — hence the blend below rather
    /// than reusing an existing color.
    let trackFill: Color

    /// Muted palette tone for the OFF state of toggles — never plain gray.
    let toggleOffTint: Color

    static func resolve(_ scheme: ColorScheme) -> AppTheme {
        scheme == .light ? .light : .dark
    }

    // MARK: AppKit semantic colors
    //
    // `Color(nsColor:)` wraps a *dynamic* NSColor — SwiftUI resolves it against the
    // window's current effective appearance at draw time, not at struct-init time. That
    // means the very same definitions below are correct for both `.light` and `.dark`
    // (the actual switch happens for free through `ThemedRootModifier`'s
    // `.preferredColorScheme`, the same mechanism already relied on elsewhere in this
    // file) — no separate light/dark RGB pairs to keep in sync by hand anymore.
    //
    // Cross-checked against the values these replaced: the old hardcoded status hexes
    // (`0x30d158`/`0x34c759`, `0xff9f0a`/`0xff9500`, `0xff453a`/`0xff3b30`) are exactly
    // Apple's own `systemGreen`/`systemOrange`/`systemRed` dark/light pair, and the old
    // accent (`0x0a84ff`/`0x007aff`) is exactly the default `controlAccentColor` — so for
    // anyone who hasn't customized System Settings › Appearance › Accent color, this is a
    // no-op visually. For anyone who *has* picked purple/pink/red/graphite/etc., the app
    // now follows that choice instead of silently overriding it with our own blue.
    private static let sysLabel = Color(nsColor: .labelColor)
    private static let sysSecondaryLabel = Color(nsColor: .secondaryLabelColor)
    private static let sysTertiaryLabel = Color(nsColor: .tertiaryLabelColor)
    private static let sysSeparator = Color(nsColor: .separatorColor)
    /// The OUTER edge of a card, deliberately denser than the hairlines INSIDE
    /// it. Raising every line together (the literal reading of "borders
    /// brighter") turns the window into a grid of boxes — what actually reads
    /// as sloppy is that a card's edge and the divider between two of its rows
    /// currently carry the same weight, so nothing says where a group starts.
    private static let sysBorderCard = Color(nsColor: .tertiaryLabelColor)
    private static let sysBorderActive = Color(nsColor:
        NSColor.separatorColor.blended(withFraction: 0.4, of: .labelColor) ?? .separatorColor)
    private static let sysWindowBackground = Color(nsColor: .windowBackgroundColor)
    private static let sysControlBackground = Color(nsColor: .controlBackgroundColor)
    private static let sysTextBackground = Color(nsColor: .textBackgroundColor)
    // Brand accent, not `controlAccentColor` (owner's call 19.08): the app
    // icon is the warm amber "Й→Q" key (#F2A24B→#E88F32) and the owner named
    // the disconnect himself — the icon's colors were nowhere inside the
    // window. The system-accent-following behavior this replaces was
    // reasonable for an anonymous utility; a branded product should look like
    // its own icon. Dark keeps the icon's amber verbatim; light darkens it —
    // #C9761A measures ≥3:1 against both light surfaces, which is what the
    // 24pt-bold stat digits (large text) need. Status colors are unaffected
    // (StatusInk is a separate system).
    private static let brandAmberDark = NSColor(srgbRed: 0.949, green: 0.635, blue: 0.294, alpha: 1)  // #F2A24B
    private static let brandAmberLight = NSColor(srgbRed: 0.788, green: 0.463, blue: 0.102, alpha: 1) // #C9761A
    private static let brandAmber = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? brandAmberDark : brandAmberLight
    }
    /// `blended(withFraction:)` resolves a dynamic color ONCE, at call time —
    /// derived tones must re-blend inside their own dynamic provider or they
    /// freeze on whichever appearance was active at static init.
    private static func brandDerived(_ blend: @escaping (NSColor) -> NSColor?) -> NSColor {
        NSColor(name: nil) { appearance in
            let base = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? brandAmberDark : brandAmberLight
            return blend(base) ?? base
        }
    }
    private static let sysHover = Color(nsColor: brandDerived {
        NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: $0)
    })
    private static let sysAccent = Color(nsColor: brandAmber)
    private static let sysAccentDeep = Color(nsColor: brandDerived {
        $0.blended(withFraction: 0.35, of: .black)
    })
    private static let sysAccentLight = Color(nsColor: brandDerived {
        $0.blended(withFraction: 0.35, of: .white)
    })
    private static let sysTrack = Color(nsColor:
        NSColor.windowBackgroundColor.blended(withFraction: 0.55, of: .separatorColor)
            ?? .windowBackgroundColor)
    // Status colors come from `StatusInk`, not straight from AppKit: plain
    // `.systemGreen` measures 2.22:1 against a light card — half the 4.5:1 the
    // text on it needs. `StatusInk` keeps the system value in dark appearance
    // and darkens it 30% in light, which is the smallest correction that
    // clears AA. See DesignTokens.swift for the measured ratios.
    private static let sysGreen = StatusInk.green
    private static let sysAmber = StatusInk.amber
    private static let sysRed = StatusInk.red

    static let dark = AppTheme(
        isDark: true,
        bgPrimary: sysWindowBackground,
        bgCard: sysControlBackground,
        bgCardHover: sysHover,
        bgInput: sysTextBackground,
        textPrimary: sysLabel,
        textSecondary: sysSecondaryLabel,
        textMuted: sysTertiaryLabel,
        accent: sysAccent,
        accentDeep: sysAccentDeep,
        accentLight: sysAccentLight,
        accentGreen: sysGreen,
        accentAmber: sysAmber,
        accentRed: sysRed,
        border: sysSeparator,
        borderCard: sysBorderCard,
        borderActive: sysBorderActive,
        trackFill: sysTrack,
        toggleOffTint: sysAccent.opacity(0.32)
    )

    static let light = AppTheme(
        isDark: false,
        bgPrimary: sysWindowBackground,
        bgCard: sysControlBackground,
        bgCardHover: sysHover,
        bgInput: sysTextBackground,
        textPrimary: sysLabel,
        textSecondary: sysSecondaryLabel,
        textMuted: sysTertiaryLabel,
        accent: sysAccent,
        accentDeep: sysAccentDeep,
        accentLight: sysAccentLight,
        accentGreen: sysGreen,
        accentAmber: sysAmber,
        accentRed: sysRed,
        border: sysSeparator,
        borderCard: sysBorderCard,
        borderActive: sysBorderActive,
        trackFill: sysTrack,
        // Was 0.16 in the first pass — measured too pale against the light card fill,
        // so raised the floor here. Still applies verbatim now that the base accent is
        // dynamic: this is an opacity offset on top of it, not a hue choice.
        toggleOffTint: sysAccent.opacity(0.28)
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

/// Quiet window background: flat canvas plus ONE ambient glow pinned to the
/// top-trailing corner, in the accent hue at 3-5% — depth without texture.
/// The cap matters: at this alpha the glow reads as light in the room, not
/// as a graphic; anything stronger starts competing with the status cover,
/// which owns the window's only meaningful color.
struct AppBackground: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        theme.bgPrimary
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent.opacity(theme.isDark ? 0.05 : 0.035), .clear],
                            center: .center, startRadius: 0, endRadius: 170
                        )
                    )
                    .frame(width: 340, height: 340)
                    .offset(x: 90, y: -110)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
    }
}

/// A grouped-list style card: system `.regularMaterial` + hairline border. HIG
/// ("Materials" → "Standard materials") recommends the `regular` thickness specifically
/// for rows with meaningful text, for contrast; using a real material here (instead of a
/// flat tinted fill) is what gives the grouped rows the same native depth as macOS
/// Settings itself, and it stays a neutral/monochrome surface — only the two decorative
/// motifs further down (status header, stats strip) carry color.
struct SettingsCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    var cornerRadius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.borderCard, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func settingsCard(cornerRadius: CGFloat = Radius.card) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius))
    }
}

/// Pill switch with a palette-tinted OFF track (never plain gray) — replaces the native
/// `.switch` toggle style so both states stay on-brand in both themes.
struct PillToggleStyle: ToggleStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .padding(Space.xxs)
                        .offset(x: configuration.isOn ? 7 : -7)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: MainTab = .status

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)

            KeycapTabBar(items: MainTab.allCases, label: \.label, selection: $selectedTab)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.md)
                .padding(.bottom, Space.sm + 2)

            Group {
                switch selectedTab {
                case .status: statusTab
                case .shortcuts: shortcutsTab
                case .more: moreTab
                }
            }
            // Without `id` + `transition` SwiftUI reuses the same view slots
            // and the text simply swaps in place — the tab thumb glides while
            // the content it selects teleports. The pair moves together now:
            // the outgoing panel fades, the incoming one fades in from a few
            // points below, matching the direction the thumb travels.
            .id(selectedTab)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                )
            )
            .padding(.horizontal, Space.xl)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selectedTab)

            footer
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
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

    /// Compact SF Symbol badge, muted semantic color from the theme — a
    /// calm "all good" seal / "needs attention" mark, never an emoji.
    private var heroIcon: String {
        switch viewModel.eventTapHealth {
        case .running:
            return viewModel.isAutoSwitchEnabled ? "checkmark.seal.fill" : "pause.circle.fill"
        case .secureInput: return "lock.circle.fill"
        case .starting: return "ellipsis.circle.fill"
        case .missingPermissions, .unavailable, .stopped: return "exclamationmark.circle.fill"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm + 2) {
            statusCover
            autoSwitchRow
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: viewModel.eventTapHealth)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: viewModel.isAutoSwitchEnabled)
    }

    /// The one tinted surface in the window. A colored "cover" was the owner's
    /// idea and it's a good one — with a condition: the tint has to MEAN the
    /// state (green running, amber blocked, red broken), not decorate the top
    /// of the window. A fixed brand banner would be the version of this that
    /// ages badly and competes with the content; a surface that changes color
    /// when the app's health changes is the fastest possible status read, and
    /// it earns the color it spends. Kept to ~7% so the words on it stay the
    /// thing you see first — everything else in the window remains uncolored,
    /// which is exactly why this one surface registers at all.
    private var statusCover: some View {
        VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: heroIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(heroColor)
                    // The status WORD stays in ink, never in the status color.
                    // Owner's verdict on the previous pass: "зелёный текст не
                    // читается" — systemGreen on a light window background is
                    // ~1.7:1, far under the 4.5:1 WCAG AA floor for body text.
                    // Color still carries the state, but through the mark next
                    // to it, where a low-contrast hue is legitimate (a glyph
                    // isn't read letter by letter) and where it reads faster.
                    // 22pt, not 19: the squint test put the status word on
                    // par with the section content — one step up makes it
                    // unambiguously the first thing the window says.
                    Text(heroWord)
                        .font(.appText(22, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                }
                Text("Определяет язык и исправляет раскладку во время набора")
                    .font(.appText(11))
                    .foregroundStyle(theme.textSecondary)
                // Permissions can be revoked after launch (System Settings,
                // TCC reset) — this is the one health state the window can't
                // fix on its own, so it gets an inline way out instead of
                // sending the user hunting for the (now-removed) menu item.
            if viewModel.needsPermissionRepair {
                Button("Настроить разрешения…", action: viewModel.openPermissionRepair)
                    .buttonStyle(.plain)
                    .font(.appText(11, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .background(alignment: .topTrailing) {
            // The mark rides ON the cover now, so the two read as one object
            // instead of a graphic floating near a headline.
            MirrorKeycapMark(
                tint: heroColor,
                ink: theme.textPrimary,
                muted: !viewModel.isAutoSwitchEnabled
            )
            .padding(.trailing, Space.md)
            .padding(.top, Space.sm)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(heroColor.opacity(theme.isDark ? 0.13 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(heroColor.opacity(theme.isDark ? 0.34 : 0.26), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var autoSwitchRow: some View {
        Toggle(isOn: $viewModel.isAutoSwitchEnabled) {
            HStack(spacing: Space.sm) {
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
        .padding(.horizontal, Space.md)
        .padding(.vertical, 11)
        .settingsCard()
        .accessibilityHint("Включает или отключает автоматическое исправление раскладки")
    }

    // MARK: Tab 1 — Статус: stats + active layouts, everything visible with no scroll.

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            statsStrip
            layoutsSection
        }
        .padding(.bottom, 4)
    }

    private var statsStrip: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle("За всё время")
            ZStack {
                KeyRowBand(tint: theme.accent)
                HStack(spacing: 0) {
                    UsageMetric(value: viewModel.autoSwitchCount, label: "исправлений")
                    metricDivider
                    UsageMetric(value: viewModel.shiftSwitchCount, label: "смен раскладки")
                    metricDivider
                    UsageMetric(value: viewModel.doubleShiftCount, label: "конвертаций слова")
                }
                .padding(.vertical, 12)
            }
            .settingsCard()
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 32)
    }

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
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
                    help: "Помнит язык для каждой программы (например, русский в Telegram, "
                        + "английский в терминале) и восстанавливает его при переключении между "
                        + "окнами. Сохраняется только идентификатор приложения — сам текст никогда "
                        + "не сохраняется.",
                    isOn: $viewModel.isPerAppLayoutEnabled
                )
            }
            .settingsCard()
        }
    }

    // MARK: Tab 2 — Клавиши

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
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
                    subtitle: "переключить последнее слово или выделенный текст",
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
                    title: "Command + Option + Shift + V",
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
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionTitle("Дополнительно")
                VStack(spacing: 0) {
                    SettingToggleRow(
                        icon: "bolt",
                        title: "Мгновенная коррекция",
                        subtitle: "исправлять слово прямо во время набора, не дожидаясь пробела",
                        help: "Исправляет прямо во время набора, не дожидаясь пробела. "
                            + "Если мешает в терминале — выключи её здесь.",
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
                    SettingToggleRow(
                        icon: "waveform",
                        title: "Звук переключения раскладки",
                        subtitle: "отдельно от общего звука — тише, только смена языка",
                        isOn: $viewModel.isLayoutSoundEnabled
                    )
                    rowDivider
                    SoundPickerRow(
                        icon: "music.note",
                        title: "Мелодия переключения",
                        subtitle: "системный звук macOS — кнопкой послушать",
                        selection: $viewModel.layoutSoundName,
                        onPreview: { viewModel.previewLayoutSound() }
                    )
                    rowDivider
                    SettingToggleRow(
                        icon: "power",
                        title: "Запускать при входе в систему",
                        subtitle: "открывать Qwerty Switcher автоматически при загрузке Mac",
                        isOn: $viewModel.isAutoStartEnabled
                    )
                    rowDivider
                    themeRow
                }
                .settingsCard()
            }
            logsSection
        }
        .padding(.bottom, 4)
    }

    // MARK: Logs — moved in from the status-bar menu (03.08.2026) so every
    // control lives inside this window; menu keeps only quick actions.

    /// One card, not two. The toggle, the actions and the preview are the same
    /// subject, and giving each its own card cost ~70pt of height for nothing —
    /// which is most of what made this tab tower over the other two and made
    /// the window lurch when you selected it.
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionTitle("Логи")
            VStack(spacing: 0) {
                SettingToggleRow(
                    icon: "text.magnifyingglass",
                    title: "Подробный лог",
                    subtitle: "писать в лог каждое слово, не только значимые события",
                    help: "Включайте, если нужно прислать диагностику. "
                        + "В обычном режиме лог не засоряется рутиной вроде каждого набранного слова.",
                    isOn: $viewModel.isVerboseLogEnabled
                )
                rowDivider
                VStack(alignment: .leading, spacing: Space.xs + 2) {
                    HStack(spacing: Space.md) {
                        Button("Показать лог") { viewModel.openLogFile() }
                        Button("Открыть папку") { viewModel.revealLogFolder() }
                        Spacer()
                        Text("хранится 5 дней")
                            .font(.appText(10))
                            .foregroundStyle(theme.textMuted)
                    }
                    .buttonStyle(.borderless)
                    .font(.appText(11, weight: .medium))
                    .foregroundStyle(theme.accent)

                    ScrollView {
                        Text(viewModel.logTail.isEmpty ? "Пока пусто" : viewModel.logTail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 78)
                    .padding(Space.xs + 2)
                    .background(theme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm + 1)
            }
            .settingsCard()
        }
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
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            FooterButton(
                icon: "text.badge.minus", title: "Исключения",
                help: "Слова и приложения, которые Qwerty Switcher никогда не трогает"
            ) {
                viewModel.onOpenExceptions?()
            }
            FooterButton(icon: "info.circle", title: "О программе") {
                viewModel.onOpenAbout?()
            }
            LicenseBadge(
                color: licenseBadgeColor, icon: licenseBadgeIcon, text: licenseService.statusSummary,
                help: "Статус подписки и активация ключа"
            ) {
                viewModel.onOpenLicense?()
            }

            Spacer()

            versionLabel
        }
    }

    /// Falls back to the bare version number (drops the "Версия" word) when the footer
    /// is too tight for the full label — e.g. a long license badge ("Лицензия · 365
    /// дн.") squeezing this trailing item. `FooterButton`/`LicenseBadge` are already
    /// `.fixedSize`, so any width shortfall used to land entirely on this Text, which
    /// had no such protection and wrapped mid-word ("Вер / сия / 0.4 / .9" — the
    /// reported bug). `ViewThatFits` now picks whichever candidate fits the space left
    /// after the fixed-size siblings, at any window width, and both candidates are
    /// still `.lineLimit(1)` so even a starved worst case clips instead of wrapping.
    private var versionLabel: some View {
        ViewThatFits(in: .horizontal) {
            Text("Версия \(appVersion)")
                .font(.appMono(11))
                .foregroundStyle(theme.textMuted)
                .monospacedDigit()
                .lineLimit(1)
            Text(appVersion)
                .font(.appMono(11))
                .foregroundStyle(theme.textMuted)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Trial → amber, active subscription → green, expired → red (все приглушённые).
    private var licenseBadgeColor: Color {
        guard licenseService.isEntitled else { return theme.accentRed }
        let isTrial = licenseService.currentPayload?.plan == "trial" || licenseService.isProvisionalTrial
        return isTrial ? theme.accentAmber : theme.accentGreen
    }

    /// "All ok" seal (active or in-grace trial) vs. attention mark (expired) —
    /// same SF-Symbols vocabulary as the hero badge.
    private var licenseBadgeIcon: String {
        licenseService.isEntitled ? "checkmark.seal.fill" : "exclamationmark.circle.fill"
    }
}

private struct LayoutPickerRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let layouts: [KeyboardLayout]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: Space.sm) {
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
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
}

/// Picker + preview button for `layoutSoundName` — separate from
/// `LayoutPickerRow` (that one lists keyboard layouts, not sounds) but same
/// row shape/spacing so it reads as one family of settings rows.
private struct SoundPickerRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selection: String
    let onPreview: () -> Void

    private var options: [String] { [SoundService.noSoundName] + SoundService.systemSoundNames }

    private func label(for name: String) -> String {
        name == SoundService.noSoundName ? "Без звука" : name
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.appText(12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.appText(10))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(action: onPreview) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(selection == SoundService.noSoundName)
            .help("Прослушать выбранный звук")

            // Selecting a new sound previews it immediately (same as clicking
            // the speaker button) — the whole point is auditioning by ear.
            Picker(title, selection: Binding(
                get: { selection },
                set: { newValue in
                    selection = newValue
                    onPreview()
                }
            )) {
                ForEach(options, id: \.self) { name in
                    Text(label(for: name)).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
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
            // Secondary, not tertiary. At 10pt these are already the smallest
            // text in the window, and tertiary label sits near 2:1 — the label
            // that names a block has to be legible, or the block reads as
            // starting nowhere.
            .foregroundStyle(theme.textSecondary)
    }
}

/// Ghost footer action button — subtle hover highlight, 0.15s ease-out.
private struct FooterButton: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: String
    let title: String
    var help: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appText(11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isHovered ? theme.bgCardHover : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .help(help ?? "")
    }
}

/// License status as a muted colored pill — SF Symbol seal/attention mark
/// (amber=trial / green=active / red=expired), no plain color dot.
private struct LicenseBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let icon: String
    let text: String
    var help: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.appText(11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(color)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 5)
            .background(color.opacity(isHovered ? 0.18 : 0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .help(help ?? "")
    }
}

private struct UsageMetric: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(value.formatted())
                .font(.appMono(24, weight: .bold))
                .foregroundStyle(theme.accent)
                .monospacedDigit()
                // These tick up while the window is open (every correction
                // posts .statsUpdated). A hard swap reads as a glitch; rolling
                // the digit says "that just happened" — which is the only
                // moment this number is interesting.
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.appText(10))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct SettingToggleRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let subtitle: String
    /// Longer explanation shown as a native tooltip on a small ⓘ icon — only
    /// when `subtitle` alone doesn't already say what the setting does.
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? theme.accent : theme.textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.appText(12, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        if let help {
                            HelpIcon(text: help)
                        }
                    }
                    Text(subtitle)
                        .font(.appText(10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .toggleStyle(.pill)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .accessibilityHint(help ?? subtitle)
    }
}

/// Small `questionmark.circle` that shows a native tooltip on hover — used
/// wherever a row's subtitle isn't enough to explain what a setting does.
/// Not `private` — reused from ExceptionsView for the same purpose.
struct HelpIcon: View {
    @Environment(\.appTheme) private var theme
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(theme.textMuted)
            .help(text)
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
