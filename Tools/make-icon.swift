// Draws Rushes' icon.
//
//     swift Tools/make-icon.swift "$(pwd)"
//
// Writes Support/AppIcon.icns. A memory card in the forest at night: the card
// in wool with its cut corner and its contacts, and on its label a crescent in
// the app's pastel sage, the colour of the one button that matters. Drawn in
// code so it follows the palette (Palette.swift) rather than being redrawn.

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

let nightTop = oklch(0.36, 0.060, 155)
let nightBottom = oklch(0.20, 0.035, 160)
let card = oklch(0.962, 0.011, 118)
let cardShade = oklch(0.85, 0.016, 120)
let contact = oklch(0.76, 0.050, 95)
let tungsten = oklch(0.86, 0.060, 150)
let label = oklch(0.21, 0.025, 162)

/// Draws the icon on a 1024 canvas, scaled to `size`.
func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // The macOS squircle: 824 wide, centred, with the shadow the grid leaves room for.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(nightBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [nightTop, nightBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The card, a little tilted, its top right corner cut as on an SD card.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -8 * .pi / 180)
    let w: CGFloat = 420, h: CGFloat = 540, r: CGFloat = 38, cut: CGFloat = 110
    let x0 = -w / 2, y0 = -h / 2, x1 = w / 2, y1 = h / 2
    let body = CGMutablePath()
    body.move(to: CGPoint(x: x0 + r, y: y0))
    body.addLine(to: CGPoint(x: x1 - r, y: y0))
    body.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
    body.addLine(to: CGPoint(x: x1, y: y1 - cut))
    body.addLine(to: CGPoint(x: x1 - cut, y: y1))
    body.addLine(to: CGPoint(x: x0 + r, y: y1))
    body.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
    body.addLine(to: CGPoint(x: x0, y: y0 + r))
    body.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
    body.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(body)
    ctx.setFillColor(card)
    ctx.fillPath()
    ctx.restoreGState()

    // The contacts along the top.
    for i in 0..<5 {
        let cx = x0 + 58 + CGFloat(i) * 52
        let contactRect = CGRect(x: cx, y: y1 - 150, width: 30, height: 92)
        ctx.addPath(CGPath(roundedRect: contactRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.setFillColor(contact)
        ctx.fillPath()
    }

    // The label: night, and a crescent of tungsten.
    let labelRect = CGRect(x: x0 + 44, y: y0 + 44, width: w - 88, height: 280)
    ctx.addPath(CGPath(roundedRect: labelRect, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(label)
    ctx.fillPath()

    let moonCenter = CGPoint(x: labelRect.midX - 6, y: labelRect.midY + 4)
    let moonRadius: CGFloat = 92
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: labelRect, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    ctx.setFillColor(tungsten)
    ctx.fillEllipse(in: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2))
    // The night bites the disc from the upper right, leaving a crescent.
    ctx.setFillColor(label)
    ctx.fillEllipse(in: CGRect(x: moonCenter.x - moonRadius + 46, y: moonCenter.y - moonRadius + 30, width: moonRadius * 2, height: moonRadius * 2))
    ctx.restoreGState()

    // A faint edge where the card's face meets its bevel.
    ctx.addPath(body)
    ctx.setStrokeColor(cardShade)
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

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
let preview = NSBitmapImageRep(cgImage: draw(size: 512))
try preview.representation(using: .png, properties: [:])!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("rushes-icon.png"))
print(output.path)
