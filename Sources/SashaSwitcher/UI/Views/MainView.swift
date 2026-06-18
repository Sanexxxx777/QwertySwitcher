import SwiftUI
import AppKit

// MARK: - NFA Design System — Liquid Glass (warm gold on deep warm charcoal)
// Shared palette across NFA Suite: Dashboard · Setup Manager · Sector Map · SashaSwitcher.

struct Gamma {
    // Surfaces
    static let bgPrimary      = Color(hex: 0x0a0a14)
    static let bgCard         = Color.white.opacity(0.06)
    static let bgCardHover    = Color.white.opacity(0.09)
    static let bgInput        = Color.white.opacity(0.08)
    static let bgElevated     = Color(hex: 0x1a1a20)

    // Text — warm off-white
    static let textPrimary    = Color(hex: 0xede6db)
    static let textSecondary  = Color(hex: 0x9a8e7d)
    static let textMuted      = Color(hex: 0x5a4f42)

    // Accent — warm gold (canonical NFA)
    static let accent         = Color(hex: 0xe89558)
    static let accentDeep     = Color(hex: 0xc97538)
    static let accentLight    = Color(hex: 0xf5b486)
    static let accentGlow     = Color(hex: 0xe89558).opacity(0.22)

    // Semantic (muted neon)
    static let accentGreen    = Color(hex: 0x5dd9a3)
    static let accentRed      = Color(hex: 0xe87171)
    static let accentCyan     = Color(hex: 0x6ac8db)
    static let accentAmber    = Color(hex: 0xe8b44c)
    static let accentPurple   = Color(hex: 0xc4a0e8)

    // Borders — white at low alpha
    static let border         = Color.white.opacity(0.08)
    static let borderActive   = Color.white.opacity(0.18)
    static let borderGlow     = Color(hex: 0xe89558).opacity(0.3)

    // Liquid Glass background gradient stops
    static let bgGradStart    = Color(hex: 0x2a1d1a)
    static let bgGradMid1     = Color(hex: 0x231a22)
    static let bgGradMid2     = Color(hex: 0x1c1a2a)
    static let bgGradMid3     = Color(hex: 0x151827)
    static let bgGradEnd      = Color(hex: 0x121423)

    // Rainbow title gradient (pink → teal → green → violet → pink)
    static let titleStops: [Color] = [
        Color(hex: 0xf5b486),
        Color(hex: 0x8fd4d0),
        Color(hex: 0xb4e28d),
        Color(hex: 0xc9a6e6),
        Color(hex: 0xf2a6c8),
    ]

    // Legacy names kept for the 4 views that reference them
    static let headerGrad1    = bgGradStart
    static let headerGrad2    = bgGradEnd
}

// MARK: - Fonts (Playfair titles, Geist sans body, Geist Mono numerics)

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

// MARK: - Rainbow gradient title

extension View {
    func nfaTitleGradient() -> some View {
        self.foregroundStyle(
            LinearGradient(colors: Gamma.titleStops, startPoint: .leading, endPoint: .trailing)
        )
    }
}

// MARK: - Liquid Glass background

struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            Gamma.bgPrimary
            LinearGradient(
                colors: [
                    Gamma.bgGradStart, Gamma.bgGradMid1,
                    Gamma.bgGradMid2, Gamma.bgGradMid3, Gamma.bgGradEnd,
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .saturation(1.05)
            RadialGradient(
                colors: [Gamma.accent.opacity(0.18), .clear],
                center: UnitPoint(x: 0, y: 1),
                startRadius: 0, endRadius: 900
            )
            LinearGradient(
                colors: [Color(white: 0.03, opacity: 0.35), .clear],
                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.28)
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass panel modifier

struct NFAGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Gamma.bgCard
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.18)
                    )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.5), radius: 20, y: 12)
    }
}

extension View {
    func nfaGlass(cornerRadius: CGFloat = 14) -> some View {
        modifier(NFAGlassPanel(cornerRadius: cornerRadius))
    }
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var viewModel: MainViewModel

    init(viewModel: MainViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ZStack {
            LiquidGlassBackground()
            VStack(spacing: 0) {
                headerSection
                statsSection
                Divider()
                    .overlay(Gamma.border)
                    .padding(.horizontal, 28)
                featuresSection
                Spacer(minLength: 8)
                bottomBar
            }
        }
        .frame(width: 620, height: 580)
        .onAppear { NSApp.appearance = nil }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Text("S A S H A")
                .font(.nfaSerif(14, weight: .medium))
                .foregroundColor(Gamma.textSecondary)
                .tracking(8)
            Text("SWITCHER")
                .font(.nfaSerif(38, weight: .semibold))
                .tracking(4)
                .nfaTitleGradient()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 14) {
            GammaStatCard(icon: "textformat.abc", hours: viewModel.autoSwitchHours,
                          label: "Автопереключение", isActive: viewModel.isAutoSwitchEnabled,
                          action: { viewModel.isAutoSwitchEnabled.toggle() })

            GammaStatCard(icon: "character.cursor.ibeam", hours: viewModel.typoFixHours,
                          label: "Опечатки", isActive: viewModel.isTypoFixEnabled,
                          action: { viewModel.isTypoFixEnabled.toggle() })

            GammaStatCard(icon: "arrow.up", hours: viewModel.shiftHours,
                          label: "Single Shift", isActive: viewModel.isSingleShiftEnabled,
                          action: { viewModel.isSingleShiftEnabled.toggle() })

            GammaStatCard(icon: "option", hours: viewModel.optionHours,
                          label: "Option", isActive: viewModel.isDoubleShiftEnabled,
                          action: { viewModel.isDoubleShiftEnabled.toggle() })
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureDesc("Double Shift", "или", "Option", " — переключить слово или выделение")
            featureDesc("Single Shift", "", "", " — поменять раскладку клавиатуры")

            Spacer().frame(height: 4)

            GammaToggle(title: "Left Shift + Right Shift", subtitle: "вкл./выключить автопереключение", isOn: $viewModel.isSplitShiftEnabled)
            GammaToggle(title: "Command + Shift + V", subtitle: "вставить текст без форматирования", isOn: $viewModel.isPasteNoFormatEnabled)
            GammaToggle(title: "Ёфикатор", subtitle: "добавление буквы ё по правилам языка", isOn: $viewModel.isYoficatorEnabled)
            GammaToggle(title: "Звук", subtitle: "автопереключения и смены раскладки", isOn: $viewModel.isSoundEnabled)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
    }

    private func featureDesc(_ b1: String, _ mid: String, _ b2: String, _ rest: String) -> some View {
        (Text(b1).fontWeight(.bold).foregroundColor(Gamma.textPrimary) +
         (mid.isEmpty ? Text("") : Text(" \(mid) ").foregroundColor(Gamma.textSecondary)) +
         (b2.isEmpty ? Text("") : Text(b2).fontWeight(.bold).foregroundColor(Gamma.textPrimary)) +
         Text(rest).foregroundColor(Gamma.textSecondary))
            .font(.system(size: 14))
    }

    // MARK: - Bottom Bar

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            gammaBottomButton("ВЕРСИЯ \(appVersion)") { viewModel.onOpenAbout?() }
            Rectangle().fill(Gamma.border).frame(width: 1, height: 20)
            gammaBottomButton("О ПРОГРАММЕ") { viewModel.onOpenAbout?() }
            Rectangle().fill(Gamma.border).frame(width: 1, height: 20)
            gammaBottomButton("ИСКЛЮЧЕНИЯ") { viewModel.onOpenExceptions?() }
        }
        .frame(height: 44)
        .background(Gamma.bgCard.opacity(0.5))
    }

    private func gammaBottomButton(_ title: String, action: @escaping () -> Void) -> some View {
        GammaBottomBtn(title: title, action: action)
    }
}

// MARK: - Stat Card

struct GammaStatCard: View {
    let icon: String
    let hours: Int
    let label: String
    let isActive: Bool
    /// Pass `nil` for info-only cards (Single Shift / Option) so they render as static metrics.
    let action: (() -> Void)?
    @State private var isPressed = false
    @State private var isHovered = false

    private var content: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .ultraLight))
                    .foregroundColor(isActive ? Gamma.accent : Gamma.textSecondary.opacity(0.35))
                    .frame(width: 90, height: 60)

                Text("\(hours) час.")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Gamma.accentGreen))
                    .offset(x: 8, y: -6)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(isActive ? Gamma.textPrimary : Gamma.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    var body: some View {
        if let action = action {
            Button(action: {
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { isPressed = false }
                SoundService.shared.playUITick()
                action()
            }) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isHovered ? Gamma.bgCard.opacity(0.8) : Gamma.bgCard.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? Gamma.border : Color.clear, lineWidth: 1)
                            )
                    )
                    .scaleEffect(isPressed ? 0.93 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isPressed)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        } else {
            content.opacity(0.85)
        }
    }
}

// MARK: - Toggle

struct GammaToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 18))
                .foregroundColor(isOn ? Gamma.accentGreen : Gamma.textSecondary.opacity(0.4))
                .scaleEffect(isPressed ? 1.2 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isPressed)

            (Text(title).fontWeight(.semibold).foregroundColor(Gamma.textPrimary) +
             Text(" — \(subtitle)").foregroundColor(Gamma.textSecondary))
                .font(.system(size: 14))

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Gamma.bgCard.opacity(0.5) : Color.clear)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isPressed = false }
            SoundService.shared.playUITick()
            withAnimation(.easeInOut(duration: 0.2)) { isOn.toggle() }
        }
    }
}

// MARK: - Bottom Button

struct GammaBottomBtn: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? Gamma.accent : Gamma.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isHovered ? Gamma.bgCard.opacity(0.5) : Color.clear)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
