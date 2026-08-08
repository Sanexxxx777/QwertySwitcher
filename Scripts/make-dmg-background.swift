#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Generates the DMG window backdrop, at 1x and 2x, straight from vectors —
// no bitmap checked into the repo, no image editor in the loop, and it stays
// crisp on Retina because the @2x file is drawn at 2x rather than scaled up.
//
// The drop target is the whole message: an arrow from where the app icon sits
// to where the Applications alias sits. Everything else stays quiet — this is
// the first thing a stranger sees of the product, and a busy installer window
// reads as a download-site wrapper, not as software someone made.

let width: CGFloat = 640
let height: CGFloat = 400

// Icon centers, kept in sync with the AppleScript in make-dmg.sh.
let appIconCenter = CGPoint(x: 170, y: 218)
let applicationsCenter = CGPoint(x: 470, y: 218)

func draw(scale: CGFloat, to url: URL) {
    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create context") }

    context.scaleBy(x: scale, y: scale)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    // Base: a very slight vertical gradient. Flat white looks unfinished on a
    // Retina display; anything stronger competes with the icons.
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.976, green: 0.976, blue: 0.980, alpha: 1),
            NSColor(srgbRed: 0.929, green: 0.933, blue: 0.945, alpha: 1)
        ]
    )
    gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The app's own motif, very faint: a keycap and its mirror, the same mark
    // the window carries. Bottom-right, well away from the icons.
    let motifTint = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 0.07)
    motifTint.setFill()
    for (dx, size, angle) in [(CGFloat(0), CGFloat(58), CGFloat(-8)), (CGFloat(46), CGFloat(68), CGFloat(7))] {
        let rect = NSRect(x: 512 + dx, y: 44, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        path.transform(using: transform as AffineTransform)
        path.fill()
    }

    // Arrow: app icon → Applications. Starts and ends clear of the 128pt icons
    // so it never runs underneath them.
    let arrowStart = CGPoint(x: appIconCenter.x + 82, y: appIconCenter.y)
    let arrowEnd = CGPoint(x: applicationsCenter.x - 82, y: applicationsCenter.y)
    let arrowColor = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 0.55)
    arrowColor.setStroke()

    let shaft = NSBezierPath()
    shaft.move(to: arrowStart)
    shaft.line(to: CGPoint(x: arrowEnd.x - 14, y: arrowEnd.y))
    shaft.lineWidth = 2.5
    shaft.lineCapStyle = .round
    shaft.stroke()

    arrowColor.setFill()
    let head = NSBezierPath()
    head.move(to: arrowEnd)
    head.line(to: CGPoint(x: arrowEnd.x - 17, y: arrowEnd.y + 9))
    head.line(to: CGPoint(x: arrowEnd.x - 17, y: arrowEnd.y - 9))
    head.close()
    head.fill()

    let title = "Перетащите Qwerty Switcher в Applications"
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1)
    ]
    let titleSize = title.size(withAttributes: titleAttributes)
    title.draw(
        at: NSPoint(x: (width - titleSize.width) / 2, y: height - 62),
        withAttributes: titleAttributes
    )

    let hint = "При первом запуске: правый клик по приложению → «Открыть»"
    let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 1)
    ]
    let hintSize = hint.size(withAttributes: hintAttributes)
    hint.draw(
        at: NSPoint(x: (width - hintSize.width) / 2, y: height - 86),
        withAttributes: hintAttributes
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else { fatalError("cannot render") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode png")
    }
    try! data.write(to: url)
    print("  wrote \(url.lastPathComponent) (\(pixelWidth)×\(pixelHeight))")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
draw(scale: 1, to: outputDirectory.appendingPathComponent("dmg-background.png"))
draw(scale: 2, to: outputDirectory.appendingPathComponent("dmg-background@2x.png"))
