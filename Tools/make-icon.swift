// Draws Rushes' icon.
//
//     swift Tools/make-icon.swift "$(pwd)"
//
// Writes Support/AppIcon.icns, and a 1024 preview in the temporary folder.
// In the family of Fil's icon (2026-11-23): a pale tile and one thread of
// accent crossing it from edge to edge. Fil's thread makes the cursive l of
// its name; Rushes' draws the SD card it reads, cut corner and contacts, and
// leaves for the drives, crossing itself as Fil's does. Sage paper, forest ink: `ground` and `accentInk` of the
// forest ambiance (Palette.swift), the icon staying the forest whatever the
// ambiance. Drawn in code so it follows the palette rather than being redrawn.

import AppKit
import CoreGraphics
import Foundation

func oklch(_ l: Double, _ c: Double, _ h: Double, _ a: Double = 1) -> CGColor {
    let hr = h * .pi / 180
    let A = c * cos(hr), B = c * sin(hr)
    let l_ = l + 0.3963377774 * A + 0.2158037573 * B
    let m_ = l - 0.1055613458 * A - 0.0638541728 * B
    let s_ = l - 0.0894841775 * A - 1.2914855480 * B
    let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
    let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
    let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
    let b = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
    func enc(_ x: Double) -> CGFloat {
        CGFloat(min(max(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0), 1 / 2.4) - 0.055, 0), 1))
    }
    return CGColor(srgbRed: enc(r), green: enc(g), blue: enc(b), alpha: CGFloat(a))
}

let paperTop = oklch(0.985, 0.008, 125)
let paperBottom = oklch(0.925, 0.026, 140)
let thread = oklch(0.46, 0.085, 155)

/// The macOS tile: a superellipse of exponent 5, 824 wide, 100 from the edge, as Fil's.
func tilePath() -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = 512 + 412 * copysign(pow(abs(c), 2.0 / 5), c)
        let y = 512 + 412 * copysign(pow(abs(s), 2.0 / 5), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The thread, in a canvas whose y runs down (as an SVG's): in from the left
/// as the card's bottom edge, up its right side, across the cut corner and the
/// top, down its left side, and out, crossing where it came in.
func threadPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 10, y: 730))
    p.addLine(to: CGPoint(x: 640, y: 730))
    p.addArc(tangent1End: CGPoint(x: 690, y: 730), tangent2End: CGPoint(x: 690, y: 680), radius: 50)
    p.addLine(to: CGPoint(x: 690, y: 362))
    p.addLine(to: CGPoint(x: 588, y: 260))
    p.addLine(to: CGPoint(x: 384, y: 260))
    p.addArc(tangent1End: CGPoint(x: 334, y: 260), tangent2End: CGPoint(x: 334, y: 310), radius: 50)
    p.addLine(to: CGPoint(x: 334, y: 600))
    p.addCurve(to: CGPoint(x: 1010, y: 800), control1: CGPoint(x: 334, y: 850), control2: CGPoint(x: 700, y: 840))
    return p
}

/// The card's contacts, three short strokes of the same thread under its top.
func contactsPath() -> CGPath {
    let p = CGMutablePath()
    for x in [420, 492, 564] as [CGFloat] {
        p.move(to: CGPoint(x: x, y: 340))
        p.addLine(to: CGPoint(x: x, y: 410))
    }
    return p
}

/// Draws the icon on a 1024 canvas, scaled to `size`.
func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // From here y runs down, as in Fil's SVG.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let tile = tilePath()

    // The tile and its soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(tile)
    ctx.setFillColor(paperBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [paperTop, paperBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // The thread. Thicker at small sizes, so it still reads at 16 px.
    ctx.addPath(threadPath())
    ctx.setStrokeColor(thread)
    ctx.setLineWidth(size <= 64 ? 72 : 52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.addPath(contactsPath())
    ctx.setLineWidth(size <= 64 ? 56 : 40)
    ctx.strokePath()
    ctx.restoreGState()

    // A hairline at the tile's edge, for light backgrounds.
    ctx.addPath(tile)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.06))
    ctx.setLineWidth(2)
    ctx.strokePath()

    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Rushes.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let image = draw(size: base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Support/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-icon.png")
try NSBitmapImageRep(cgImage: draw(size: 1024)).representation(using: .png, properties: [:])!.write(to: previewURL)
print(output.path)
print(previewURL.path)
