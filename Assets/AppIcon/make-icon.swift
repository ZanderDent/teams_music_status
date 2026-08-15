// make-icon.swift — draw the Teams Music Status app icon and emit an .icns.
//
//   swift Assets/AppIcon/make-icon.swift Assets/AppIcon
//
// The artwork is drawn here in code rather than shipped as a binary blob so it is
// reviewable in a diff, reproducible, and unambiguously original.
//
// Design: a music note sitting on a rounded-square field, with a presence dot in the
// corner — "what I'm playing" plus "my status". Deliberately generic music iconography;
// nothing here references Microsoft Teams or Spotify, whose marks are trademarks and
// whose use would imply an affiliation that does not exist.
//
// The note glyph is hand-built from Bezier paths. SF Symbols are NOT used: Apple's SF
// Symbols licence forbids using them in application icons.
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

// macOS icons are drawn inside a rounded square that occupies about 80% of the canvas,
// leaving room for the shadow the system expects. These proportions follow Apple's
// macOS app icon template.
let contentInsetRatio: CGFloat = 0.094
let cornerRadiusRatio: CGFloat = 0.2237

func draw(size: CGFloat) -> CGImage? {
    let scale: CGFloat = 1
    let pixels = Int(size * scale)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * contentInsetRatio
    let plate = canvas.insetBy(dx: inset, dy: inset)
    let radius = plate.width * cornerRadiusRatio

    // ── Plate ────────────────────────────────────────────────────────────────
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)

    // Soft drop shadow, as macOS icons have.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(platePath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    // Indigo→violet gradient. Distinct from both Teams' blue-purple and Spotify's green.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.36, green: 0.31, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.55, green: 0.27, blue: 0.80, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY),
                                   options: [])
    }
    // Gentle highlight across the top, which reads as depth at large sizes and
    // disappears harmlessly at 16pt.
    if let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                       NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: plate.midX, y: plate.maxY),
                                   end: CGPoint(x: plate.midX, y: plate.midY),
                                   options: [])
    }
    context.restoreGState()

    // ── Music note ───────────────────────────────────────────────────────────
    // A beamed eighth note: two heads, two stems, one connecting beam. Drawn from
    // primitives so it stays crisp at every size.
    let noteColor = NSColor.white.cgColor
    let u = plate.width                       // unit for proportional maths
    let stemWidth = u * 0.052
    let headW = u * 0.225
    let headH = u * 0.165
    let leftHeadCenter = CGPoint(x: plate.minX + u * 0.285, y: plate.minY + u * 0.395)
    let rightHeadCenter = CGPoint(x: plate.minX + u * 0.575, y: plate.minY + u * 0.330)
    let stemTopY = plate.minY + u * 0.790

    context.saveGState()
    context.setFillColor(noteColor)
    context.setShadow(offset: CGSize(width: 0, height: -u * 0.012),
                      blur: u * 0.04,
                      color: NSColor(srgbRed: 0.16, green: 0.10, blue: 0.35, alpha: 0.35).cgColor)

    // Note heads, tilted the way engraved notation draws them.
    for center in [leftHeadCenter, rightHeadCenter] {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: -.pi / 9)
        context.addEllipse(in: CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH))
        context.fillPath()
        context.restoreGState()
    }

    // Stems, rising from the right edge of each head.
    let leftStemX = leftHeadCenter.x + headW * 0.40
    let rightStemX = rightHeadCenter.x + headW * 0.40
    context.fill(CGRect(x: leftStemX - stemWidth / 2, y: leftHeadCenter.y,
                        width: stemWidth, height: stemTopY - leftHeadCenter.y))
    context.fill(CGRect(x: rightStemX - stemWidth / 2, y: rightHeadCenter.y,
                        width: stemWidth, height: stemTopY - u * 0.070 - rightHeadCenter.y))

    // Beam joining the two stems, angled slightly like real notation.
    let beamThickness = u * 0.105
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: leftStemX - stemWidth / 2, y: stemTopY))
    beam.addLine(to: CGPoint(x: rightStemX + stemWidth / 2, y: stemTopY - u * 0.070))
    beam.addLine(to: CGPoint(x: rightStemX + stemWidth / 2, y: stemTopY - u * 0.070 - beamThickness))
    beam.addLine(to: CGPoint(x: leftStemX - stemWidth / 2, y: stemTopY - beamThickness))
    beam.closeSubpath()
    context.addPath(beam)
    context.fillPath()
    context.restoreGState()

    // ── Presence dot ─────────────────────────────────────────────────────────
    // The "status" half of the idea: an availability dot, like the one every chat app
    // puts on an avatar. Ringed in the plate colour so it reads as a badge sitting on
    // top rather than a hole punched through.
    let dotRadius = u * 0.122
    let dotCenter = CGPoint(x: plate.maxX - u * 0.180, y: plate.minY + u * 0.180)
    let ringWidth = u * 0.048

    context.setFillColor(NSColor(srgbRed: 0.42, green: 0.28, blue: 0.84, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius - ringWidth,
                                   y: dotCenter.y - dotRadius - ringWidth,
                                   width: (dotRadius + ringWidth) * 2,
                                   height: (dotRadius + ringWidth) * 2))
    context.setFillColor(NSColor(srgbRed: 0.20, green: 0.83, blue: 0.44, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                                   width: dotRadius * 2, height: dotRadius * 2))

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

// .iconset requires these exact names; iconutil rejects anything else.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    guard let image = draw(size: variant.pixels) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent(variant.name))
}

// A single large preview, handy for the README and for eyeballing the artwork.
if let preview = draw(size: 1024) {
    try write(preview, to: URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent("AppIcon-preview.png"))
}

print("wrote \(variants.count) sizes to \(iconset.path)")
