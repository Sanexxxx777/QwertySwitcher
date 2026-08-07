import SwiftUI

// MARK: - The app's one graphic idea
//
// Qwerty Switcher does exactly one thing: it notices you typed a word in the wrong
// alphabet and rewrites it in the right one. The motif is that idea, drawn: two
// keycaps carrying the *same* glyph, the second one mirrored — because a mirrored
// Latin "R" is a Cyrillic "Я". One shape, two writing systems, which is the whole
// product in a single mark. It's also already the app's icon language (a keycap
// plate with a second keycap behind it), so the window and the Dock icon now speak
// the same visual sentence instead of two unrelated ones.
//
// Everything here is vector — `RoundedRectangle`, `LinearGradient`, `Text` — so there
// is no bitmap in the bundle, it stays crisp at any scale and on any display, and it
// costs nothing to ship. The layer never animates on its own: it only moves when the
// app's health state actually changes, and only when Reduce Motion is off (the caller
// owns that decision via `.animation(_:value:)`). It never takes a click.

/// One key. A base (the key's body, in shadow) with a top face inset inside it — the
/// two-part construction is what makes it read as a physical object rather than a
/// rounded rectangle. Face radius is derived from the base radius minus the inset, so
/// the corners stay concentric at every size (see `Radius`).
struct Keycap: View {
    let glyph: String
    var mirrored: Bool = false
    let tint: Color
    let ink: Color
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Radius.keycapBase(size), style: .continuous)
                .fill(tint.opacity(0.34))

            RoundedRectangle(cornerRadius: Radius.keycapFace(size), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.11)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.keycapFace(size), style: .continuous)
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                )
                .overlay(
                    // The legend stays *ink*, never tinted: measured at 13.6:1 against
                    // the light face and 9.3:1 against the dark one. The state color
                    // lives in the surface it sits on, which is exactly the split Apple
                    // recommends — color on the background, not on the glyph.
                    Text(glyph)
                        .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .center)
                )
                .frame(width: size - Radius.keycapFaceInset * 2,
                       height: size - Radius.keycapFaceInset * 3)
                .padding(.top, Radius.keycapFaceInset)
        }
        .frame(width: size, height: size)
    }
}

/// The header mark: "R" and its mirror. Tint follows the app's health state, so the
/// composition genuinely changes with what the app is doing rather than being a static
/// sticker — running is green, paused reads back in neutral ink, a problem turns it red.
/// When paused, the mirrored key also drops in opacity: the pair stops "agreeing", which
/// says *not currently converting* without a word of copy.
struct MirrorKeycapMark: View {
    let tint: Color
    let ink: Color
    var muted: Bool = false

    var body: some View {
        HStack(spacing: -5) {
            Keycap(glyph: "R", tint: tint, ink: ink, size: 34)
                .rotationEffect(.degrees(-5))
                .offset(y: 2)
            Keycap(glyph: "R", mirrored: true, tint: tint, ink: ink, size: 40)
                .rotationEffect(.degrees(5))
                .opacity(muted ? 0.4 : 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A keyboard row surfacing at the bottom edge of the statistics card, clipped by the
/// card itself so the keys read as continuing past it. Two staggered rows, because a
/// single row of squares is just a dotted line — the half-step offset between rows is
/// the thing the eye recognises as a keyboard.
///
/// This replaces the previous decorative pass, which was two heavily blurred blobs at
/// 6–9% opacity. At that blur radius a shape stops being a shape: it reads as a smudge
/// on the display, which is precisely the complaint it earned. Crisp geometry at low
/// opacity is quiet *and* intentional; blurred geometry is only quiet.
struct KeyRowBand: View {
    let tint: Color

    private let keySize: CGFloat = 15
    private let gap: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let step = keySize + gap
            let count = Int(ceil(geo.size.width / step)) + 2
            VStack(alignment: .leading, spacing: gap) {
                row(count: count, opacity: 0.07, leadingOffset: -step / 2)
                row(count: count, opacity: 0.11, leadingOffset: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            // Pushes the lower row's bottom half past the card's edge, so the band is
            // cropped by the card instead of sitting neatly inside it.
            .offset(y: keySize * 0.55)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(count: Int, opacity: Double, leadingOffset: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: keySize * 0.28, style: .continuous)
                    .fill(tint.opacity(opacity))
                    .frame(width: keySize, height: keySize)
            }
        }
        .offset(x: leadingOffset)
    }
}

// MARK: - Tabs
//
// The previous tab strip was a stock segmented `Picker` with `.tint(accent)` forced onto
// it, which fills the selected segment with saturated accent — a treatment macOS itself
// stopped using, and the single loudest object in a window whose job is to be calm. HIG
// ("Color" → Liquid Glass color) is explicit about it: *"Refrain from adding color to the
// background of multiple controls"*, and reserve tinted backgrounds for a primary action.
// A tab bar is navigation, not a primary action.
//
// So the selected tab becomes a key that's pressed: a raised neutral face on a recessed
// track, in the same keycap language as the header mark. Selection now costs zero color —
// it reads by elevation and weight, which is what the rest of macOS does too.

struct KeycapTabBar<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let isOn = item == selection
                // Both branches must be spelled as the same OptionSet type —
                // a ternary between `[.isButton, .isSelected]` and `.isButton`
                // makes the type-checker give up on the whole `body`.
                let traits: AccessibilityTraits = isOn ? [.isButton, .isSelected] : [.isButton]
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.appText(12, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: Radius.tabThumb, style: .continuous)
                                    .fill(theme.bgCard)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.tabThumb, style: .continuous)
                                            .strokeBorder(theme.border, lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12),
                                            radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "tabThumb", in: thumb)
                            }
                        }
                }
                .buttonStyle(.plain)
                // A hand-built control has to re-declare what the stock Picker gave for
                // free, or VoiceOver announces three unrelated buttons.
                .accessibilityAddTraits(traits)
            }
        }
        .padding(Radius.tabInset)
        .background(
            RoundedRectangle(cornerRadius: Radius.tabTrack, style: .continuous)
                .fill(theme.trackFill)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                   value: selection)
    }
}
