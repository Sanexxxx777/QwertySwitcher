#!/usr/bin/env swift
// Qwerty Switcher — App Icon + status bar icon preview generator.
//
// Draws the app icon vectorially (CoreGraphics/AppKit, no external assets)
// and rasterizes it at every size iconutil needs for a .icns. Also renders
// a preview sheet of the status bar badge states so the drawing routine in
// StatusBarController.swift can be eyeballed without launching the app.
//
// Everything is drawn through a raw CGContext bitmap (CGContext(data:...)),
// never through NSView.cacheDisplay/CALayer rendering — on this machine's
// macOS 27 beta, cacheDisplay-based rendering of *rotated* CGPath fills
// comes out visibly warped (confirmed with an isolated repro: identical
// path filled via raw CGContext is clean, via NSView+cacheDisplay is wavy).
// Raw CGContext sidesteps that pipeline entirely and is also what lets us
// rasterize at an exact pixel size regardless of the display's backing
// scale factor (cacheDisplay silently doubled every size on this Retina
// machine).
//
// Usage:
//   swiftc Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <outDir>
//
// Writes:
//   <outDir>/AppIcon-1024.png
//   <outDir>/AppIcon.iconset/icon_*.png  (all 10 sizes iconutil expects)
//   <outDir>/statusbar-*.png             (EN / RU / paused / "!" states, @8x)

import AppKit
import CoreText

// MARK: - Palette (matches app's graphite + systemBlue language, see CLAUDE.md)

enum Palette {
    static let graphiteTop = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1)   // #25252A
    static let graphiteBottom = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.078, alpha: 1) // #121214
    static let accentBlueLight = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)  // #0a84ff
    static let accentBlueDark = NSColor(srgbRed: 0.0, green: 0.353, blue: 0.788, alpha: 1)   // #005ac9
    static let paper = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1)          // #f6f6f8
    static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.122, alpha: 1)              // #1c1c1f
}

// MARK: - Squircle (continuous-corner) mask

/// A macOS/Big-Sur-style "continuous corner" squircle, built as a superellipse
/// (|x/a|^n + |y/a|^n = 1, n = 5). This isn't Apple's exact undisclosed corner
/// curve, but n=5 reproduces their public 22.37%-of-side corner radius almost
/// exactly: a superellipse's corner-to-center distance at n=5 is 1.231×a vs.
/// 1.229×a for a circular-arc round-rect with r=0.2237×side — a <0.2% gap,
/// close enough to be visually indistinguishable, and it's a real smooth
/// (G1-continuous) curve rather than arc-jointed segments.
func superellipsePath(size: CGFloat, n: Double = 5.0, pointCount: Int = 360) -> CGPath {
    let a = Double(size) / 2
    let path = CGMutablePath()
    for i in 0..<pointCount {
        let t = 2 * Double.pi * Double(i) / Double(pointCount)
        let c = cos(t), s = sin(t)
        let x = a * (c == 0 ? 0 : (c < 0 ? -1 : 1) * pow(abs(c), 2 / n))
        let y = a * (s == 0 ? 0 : (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        let point = CGPoint(x: a + x, y: a + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// Rounded-square path, already rotated + translated (transform baked into
/// the path itself rather than the CTM, so `ctx.setShadow` stays predictable).
func roundedSquarePath(center: CGPoint, side: CGFloat, cornerRatio: CGFloat, rotationDegrees: CGFloat) -> CGPath {
    let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    let corner = side * cornerRatio
    let base = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    var t = CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180)
        .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    return base.copy(using: &t) ?? base
}

// MARK: - Raw CGContext bitmap rendering

func renderToPNGRep(size: CGSize, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let w = max(1, Int(size.width.rounded()))
    let h = max(1, Int(size.height.rounded()))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let cgImage = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: cgImage)
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(url.path)")
    }
    try? data.write(to: url)
}

// MARK: - Letterform (Cyrillic "Я") via CoreText glyph path

/// Returns the outline of `char` in `font`, in font units (not yet scaled).
func glyphPath(for char: Character, font: NSFont) -> CGPath? {
    let ctFont = font as CTFont
    let utf16 = Array(String(char).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    var chars = utf16
    guard CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count), let g = glyphs.first, g != 0 else {
        return nil
    }
    return CTFontCreatePathForGlyph(ctFont, g, nil)
}

/// Path for "Я" scaled to fill `targetHeightRatio` of `canvasSize`, with its
/// own origin at (0,0)-ish (bounding box min moved to origin) so callers can
/// position/rotate it like any other shape.
func russianYaPath(canvasSize: CGFloat, targetHeightRatio: CGFloat) -> CGPath {
    let font = NSFont.systemFont(ofSize: canvasSize * 0.6, weight: .heavy)
    guard let raw = glyphPath(for: "Я", font: font) else { fatalError("no glyph for Я") }
    let box = raw.boundingBoxOfPath
    let targetHeight = canvasSize * targetHeightRatio
    let scale = targetHeight / box.height

    var t = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    return raw.copy(using: &t) ?? raw
}

// MARK: - Icon content

func drawAppIcon(ctx: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // 0. Clip everything to the continuous-corner squircle.
    ctx.addPath(superellipsePath(size: size))
    ctx.clip()

    // 1. Graphite background — subtle vertical depth gradient.
    let bgGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.graphiteTop.cgColor, Palette.graphiteBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

    // 2. Soft inner top highlight (glass depth, Big Sur guideline).
    ctx.saveGState()
    ctx.addRect(rect)
    ctx.clip()
    let highlightGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.16).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(highlightGradient,
                            start: CGPoint(x: 0, y: size),
                            end: CGPoint(x: 0, y: size * 0.55),
                            options: [])
    ctx.restoreGState()

    // 3. Back "key" card — systemBlue, offset down-right, slight rotation:
    //    the state the layout is switching *to*.
    let cardSide = size * 0.46
    let cornerRatio: CGFloat = 0.30
    let backCenter = CGPoint(x: size * 0.55, y: size * 0.45)
    let backPath = roundedSquarePath(center: backCenter, side: cardSide, cornerRatio: cornerRatio, rotationDegrees: -9)
    let cardGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.accentBlueLight.cgColor, Palette.accentBlueDark.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(backPath)
    ctx.clip()
    ctx.drawLinearGradient(cardGradient,
                            start: CGPoint(x: backCenter.x - cardSide / 2, y: backCenter.y + cardSide / 2),
                            end: CGPoint(x: backCenter.x + cardSide / 2, y: backCenter.y - cardSide / 2),
                            options: [])
    ctx.restoreGState()

    // 4. Front "key" card — paper white, the corrected state, drawn on top
    //    with a soft drop shadow to lift it off the background.
    let frontCenter = CGPoint(x: size * 0.465, y: size * 0.52)
    let frontPath = roundedSquarePath(center: frontCenter, side: cardSide, cornerRatio: cornerRatio, rotationDegrees: 5)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.014), blur: size * 0.022,
                  color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(frontPath)
    ctx.setFillColor(Palette.paper.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 5. "Я" glyph, ink graphite, centered on the front card (rotated to match).
    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    let glyphFlat = russianYaPath(canvasSize: cardSide, targetHeightRatio: 0.60)
    let glyphBox = glyphFlat.boundingBoxOfPath
    var glyphTransform = CGAffineTransform(translationX: -glyphBox.midX, y: -glyphBox.midY)
        .concatenating(CGAffineTransform(rotationAngle: 5 * .pi / 180))
        .concatenating(CGAffineTransform(translationX: frontCenter.x, y: frontCenter.y))
    let glyph = glyphFlat.copy(using: &glyphTransform) ?? glyphFlat
    ctx.addPath(glyph)
    ctx.setFillColor(Palette.ink.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Status bar badge (mirrors StatusBarController.makeStatusImage)

func drawStatusBadge(ctx: CGContext, canvasSize: CGSize, label: String, paused: Bool) {
    let alpha: CGFloat = paused ? 0.45 : 1.0
    let inset: CGFloat = 1
    let rect = CGRect(x: inset, y: inset, width: canvasSize.width - 2 * inset, height: canvasSize.height - 2 * inset)
    let radius: CGFloat = 5
    let badge = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
    ctx.addPath(badge)
    ctx.fillPath()

    let fontSize: CGFloat = label.count <= 2 ? 10.5 : 9
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.black,
        .kern: 0.3,
    ]
    let attr = NSAttributedString(string: label, attributes: attrs)
    let textSize = attr.size()
    let origin = CGPoint(x: (canvasSize.width - textSize.width) / 2,
                          y: (canvasSize.height - textSize.height) / 2 - 0.5)

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = nsCtx
    nsCtx.compositingOperation = .destinationOut
    attr.draw(at: origin)
    NSGraphicsContext.current = previous
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: make-icon <outDir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// 1. Master 1024 (also doubles as icon_512x512@2x.png).
let master = renderToPNGRep(size: CGSize(width: 1024, height: 1024)) { ctx in
    drawAppIcon(ctx: ctx, size: 1024)
}
writePNG(master, to: outDir.appendingPathComponent("AppIcon-1024.png"))

// 2. Every size iconutil needs for a full .icns.
let iconsetSizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconsetSizes {
    let rep = renderToPNGRep(size: CGSize(width: px, height: px)) { ctx in
        drawAppIcon(ctx: ctx, size: px)
    }
    writePNG(rep, to: iconsetDir.appendingPathComponent("\(name).png"))
}

// 3. Status bar badge preview sheet — 4 states, native 26×18 + @8x for review.
let states: [(String, String, Bool)] = [
    ("en", "EN", false), ("ru", "RU", false), ("paused", "RU", true), ("health", "!", true),
]
for (name, label, paused) in states {
    let scale: CGFloat = 8
    let native = CGSize(width: 26, height: 18)
    let big = CGSize(width: native.width * scale, height: native.height * scale)
    let rep = renderToPNGRep(size: big) { ctx in
        ctx.scaleBy(x: scale, y: scale)
        drawStatusBadge(ctx: ctx, canvasSize: native, label: label, paused: paused)
    }
    writePNG(rep, to: outDir.appendingPathComponent("statusbar-\(name).png"))
}

print("wrote icon set to \(outDir.path)")
