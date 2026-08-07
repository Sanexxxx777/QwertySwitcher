import SwiftUI
import AppKit

// MARK: - Spatial scale
//
// Before this file the window used 4/5/6/8/10/11/12/14/16/18/20/24 more or less
// interchangeably, which is why nothing in it had a beat: a 14pt gap between two
// *sections* and a 12pt gap between a *label and its own card* are close enough in
// value that the eye can't tell which grouping is which. One scale, used everywhere,
// is what makes grouping legible without drawing a single extra line.

enum Space {
    /// Hairline-adjacent: gap between a glyph and the word it belongs to.
    static let xxs: CGFloat = 3
    /// Inside a single label stack (title over subtitle).
    static let xs: CGFloat = 6
    /// Between a control and its icon; row padding (vertical).
    static let sm: CGFloat = 10
    /// Row padding (horizontal), gap between a section title and its card.
    static let md: CGFloat = 14
    /// Between two sections that belong to the same tab.
    static let lg: CGFloat = 16
    /// Window margin.
    static let xl: CGFloat = 20
}

// MARK: - Corner radii
//
// Nested rounded rectangles only look concentric when the inner radius equals the
// outer radius minus the gap between them. Get it wrong and the corners visibly
// "squint" — the inner shape's arc runs at a different rate than the outer one.
// Every pair below is derived, not eyeballed, and the derivation is written out so
// a later edit to one value can't silently break the pair.

enum Radius {
    /// Outer card / hero panel.
    static let card: CGFloat = 12
    /// Tab bar track.
    static let tabTrack: CGFloat = 10
    /// Padding between the track's edge and the selected thumb.
    static let tabInset: CGFloat = 3
    /// tabTrack − tabInset.
    static var tabThumb: CGFloat { tabTrack - tabInset }
    /// Keycap base (the key's body).
    static func keycapBase(_ size: CGFloat) -> CGFloat { size * 0.30 }
    /// Inset of the key's top face inside its body.
    static let keycapFaceInset: CGFloat = 2
    /// keycapBase − keycapFaceInset.
    static func keycapFace(_ size: CGFloat) -> CGFloat { keycapBase(size) - keycapFaceInset }
}

// MARK: - Status ink
//
// The one place in this app that legitimately hardcodes color values, and the reason
// is measured, not stylistic. `NSColor.systemGreen` in *light* appearance is #34C759,
// which lands at **2.22:1** against a white card and **1.88:1** against the window
// background — so the previous build's green "Работает" headline was not merely hard to
// read, it failed WCAG AA (4.5:1) by a factor of two and missed even the 3:1 floor for
// meaningful non-text graphics. Apple's own guidance ("Color" → Best practices) says to
// use system colors *and* to keep sufficient contrast; on a light background those two
// instructions conflict for green and orange, and contrast is the one that decides
// whether a person can read the word at all.
//
// So: in *dark* appearance the system values already clear AA comfortably and are used
// verbatim. In *light* appearance each is the same hue blended 30% toward black — the
// smallest correction that clears 4.5:1 (green 4.32:1, amber 4.29:1, red 6.46:1 against
// the card). Ratios are recomputed whenever these change; the arithmetic lives in the
// project's contrast check, not in anyone's judgement.
//
// This palette is used for status *ink* (the small state glyph, the license badge mark)
// and for the decorative keycap motif. Body text, base surfaces, separators and the
// accent stay on AppKit's dynamic semantic colors — see `AppTheme`.

enum StatusInk {
    /// Resolves per-appearance at draw time, so both themes are correct with no
    /// duplicated view code. Literal values only inside the provider — deliberately no
    /// `blended(withFraction:of:)` here, because that would resolve against whatever
    /// appearance happened to be current when the static was first touched and then
    /// stay frozen at that value for the process's lifetime.
    private static func pair(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
                green: Double((hex >> 8) & 0xFF) / 255.0,
                blue: Double(hex & 0xFF) / 255.0,
                alpha: 1)
    }

    /// systemGreen darkened 30% for light (4.32:1 on card) / systemGreen dark (8.25:1).
    static let green = pair(light: srgb(0x248B3E), dark: srgb(0x30D158))
    /// systemOrange darkened 30% for light (4.29:1) / systemOrange dark (8.11:1).
    static let amber = pair(light: srgb(0xB26800), dark: srgb(0xFF9F0A))
    /// systemRed darkened 30% for light (6.46:1) / systemRed dark (4.89:1).
    static let red = pair(light: srgb(0xB22922), dark: srgb(0xFF453A))
}
