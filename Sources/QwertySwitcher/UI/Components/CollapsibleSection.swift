import SwiftUI
import AppKit

// MARK: - Collapsible settings section
//
// The "Ещё" tab grew past the height of a laptop screen: eight groups of
// controls, all expanded at once, so opening the tab meant meeting a wall of
// switches with the bottom of it cut off by the screen edge. Collapsing is not
// decoration here — it is what makes the tab *scannable*: six closed headers
// fit in one glance, and each one carries a summary line so the state of a
// group is readable without opening it.

/// One collapsible group inside a settings tab: a tappable header row (icon,
/// title, one-line summary, chevron) over content that unfolds beneath it.
/// The header follows the same metrics as `SettingToggleRow` — 20pt icon
/// column, `Space.md` horizontal / `Space.sm` vertical padding — so a closed
/// group and an open row read as the same family of object.
struct CollapsibleSection<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let icon: String
    let title: String
    /// State of the group, readable while it is closed ("включено 4 из 5").
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)
                content()
            }
        }
        .settingsCard()
    }

    // The unfold itself is deliberately NOT animated inside SwiftUI. The window
    // sizes itself to this content, so an animated height sends AppKit a new
    // frame on every animation tick; `SmoothResizeWindow` starts a 0.24s
    // animation on the first one and then jumps for all the rest — which is
    // exactly the stutter this replaces. One instant layout change = one
    // window resize = one smooth animation, run by the window.
    private func toggleExpanded() {
        isExpanded.toggle()
    }

    private var header: some View {
        Button(action: toggleExpanded) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isExpanded ? theme.accent : theme.textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.appText(12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(summary)
                        .font(.appText(10))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: Space.sm)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isExpanded ? theme.accent : theme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isExpanded)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(headerFill)
        .overlay(alignment: .leading) {
            // A 3pt accent edge on the open group. The header is the one row in
            // the card that is a control rather than a setting, and once the
            // group unfolds it otherwise reads as just the first line of the
            // list — this is what keeps it findable when you want to close it
            // again.
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)
                .opacity(isExpanded ? 1 : 0)
        }
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
        }
        .accessibilityLabel("\(title). \(summary)")
        .accessibilityValue(isExpanded ? "развёрнуто" : "свёрнуто")
        .accessibilityAddTraits(.isButton)
    }

    /// Closed and idle the header is transparent — six tinted bars stacked on
    /// top of each other would read as noise. It tints on hover (this row is
    /// clickable) and stays tinted while open (this row is the one that closes
    /// the group again).
    private var headerFill: Color {
        if isExpanded { return theme.bgInput.opacity(isHovering ? 0.95 : 0.7) }
        return isHovering ? theme.bgInput.opacity(0.55) : .clear
    }
}
