import AppKit
import SwiftUI

/// Cairn's design system, carried over, moved into the forest, then softened.
///
/// Steven asked on 2026-09-21 for Cairn's look in forest green, then the same
/// day for something sober, minimal, serif and sans, in pastels. Same structure
/// as Cairn's `Palette` (and Journal's before it): tokens in OKLCH, one colour
/// per role resolving itself per appearance. The ground is wool with a breath
/// of lichen, the ink a pine slate. The accent is split in three, because a
/// pastel cannot carry text: `accent` is the pastel sage that fills (the button,
/// a chosen chip, a ticked kind), `accentInk` the deep forest that writes
/// (links, what is checked), `accentLine` the green that draws (bars, strokes).
///
/// Every pair was measured before it went in. Text: the weakest are `alert` on
/// `groundSunk` in light, 4.52:1, and `inkFaint` on `groundSunk` in light,
/// 4.64:1; `onAccent` on `accent` is 9.07:1 light, 9.88:1 dark. Lines:
/// `accentLine` against the bar's track, 3.17:1 light, 5.07:1 dark.
enum Palette {
    // MARK: OKLCH

    static func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: Double = 1) -> Color {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let L = l_ * l_ * l_
        let M = m_ * m_ * m_
        let S = s_ * s_ * s_

        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S

        func encode(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0), 1 / 2.4) - 0.055
            return Swift.min(Swift.max(v, 0), 1)
        }

        return Color(.sRGB, red: encode(r), green: encode(g), blue: encode(bl), opacity: alpha)
    }

    static func dynamic(_ light: Color, _ dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    // MARK: Ground and ink

    /// Wool with a breath of lichen. The forest at night in dark.
    static let ground = dynamic(oklch(0.962, 0.011, 118), oklch(0.195, 0.014, 165))
    /// The cards' column: a shade deeper, as Cairn's sidebar is.
    static let groundSunk = dynamic(oklch(0.936, 0.015, 122), oklch(0.165, 0.013, 165))
    /// A block on the page, a sheet, a popover: paler ivory.
    static let surface = dynamic(oklch(0.988, 0.006, 105), oklch(0.232, 0.015, 165))
    static let surfaceRaised = dynamic(oklch(0.997, 0.003, 100), oklch(0.268, 0.016, 165))

    /// Pine slate.
    static let ink = dynamic(oklch(0.25, 0.020, 160), oklch(0.94, 0.010, 110))
    static let inkSoft = dynamic(oklch(0.44, 0.020, 160), oklch(0.77, 0.014, 130))
    static let inkFaint = dynamic(oklch(0.515, 0.018, 155), oklch(0.655, 0.014, 140))

    static let hairline = dynamic(oklch(0.885, 0.014, 120), oklch(0.31, 0.014, 165))
    static let hairlineStrong = dynamic(oklch(0.82, 0.016, 125), oklch(0.40, 0.015, 165))

    /// The row under the pointer, a wash of ink.
    static let hover = dynamic(oklch(0.25, 0.020, 160, 0.05), oklch(0.94, 0.010, 110, 0.06))

    // MARK: The forest, in pastel

    /// Pastel sage: the one button, a chosen chip, a ticked kind. Always with
    /// `onAccent` on it, and a hairline of `accentLine` to hold its shape on
    /// the pale ground.
    static let accent = dynamic(oklch(0.865, 0.055, 150), oklch(0.80, 0.070, 150))
    static let onAccent = dynamic(oklch(0.30, 0.045, 155), oklch(0.20, 0.030, 155))
    /// The deep forest that writes: links, "déjà sauvegardé", a checked mark.
    /// 6.13:1 on the ground in light, 10.74:1 in dark.
    static let accentInk = dynamic(oklch(0.46, 0.085, 155), oklch(0.82, 0.075, 150))
    /// The green that draws: bars, strokes, a checkbox's edge.
    static let accentLine = dynamic(oklch(0.56, 0.090, 152), oklch(0.70, 0.085, 150))
    /// Paler still: the naming example, a selected row.
    static let accentSoft = dynamic(oklch(0.935, 0.028, 150), oklch(0.30, 0.035, 155))

    /// The top of the page, the forest fading into the ground.
    static let wash: [Color] = [
        dynamic(oklch(0.88, 0.045, 150, 0.35), oklch(0.55, 0.060, 155, 0.12)),
        dynamic(oklch(0.962, 0.011, 118, 0), oklch(0.195, 0.014, 165, 0)),
    ]

    // MARK: Signals, Cairn's own

    /// Something to look at before going on: a missing client, a drive that is
    /// not plugged in. Cairn's peat. 5.22:1 on the sunk ground in light.
    static let late = dynamic(oklch(0.50, 0.120, 50), oklch(0.74, 0.110, 50))
    static let lateSoft = dynamic(oklch(0.93, 0.035, 50), oklch(0.31, 0.045, 50))
    /// Something did not make it. Cairn's sea thrift, the colour of listening
    /// there and of a failed copy here: both mean "look now".
    static let alert = dynamic(oklch(0.54, 0.135, 12), oklch(0.74, 0.120, 12))
    static let alertSoft = dynamic(oklch(0.93, 0.035, 12), oklch(0.32, 0.050, 12))

    // MARK: Cameras

    /// Cairn's project hues, one per camera letter so A and D read apart, as
    /// pastels: a pale fill and a deep ink of the same hue, 7.6:1 at worst.
    static let cameraHues: [Double] = [245, 45, 320, 115, 195, 5, 70, 150]

    static func camera(_ label: String) -> Color {
        let hue = cameraHue(label)
        return dynamic(oklch(0.90, 0.045, hue), oklch(0.38, 0.045, hue))
    }

    static func onCamera(_ label: String) -> Color {
        let hue = cameraHue(label)
        return dynamic(oklch(0.37, 0.065, hue), oklch(0.90, 0.040, hue))
    }

    private static func cameraHue(_ label: String) -> Double {
        let index = Int(label.uppercased().unicodeScalars.first?.value ?? 65) - 65
        return cameraHues[((index % cameraHues.count) + cameraHues.count) % cameraHues.count]
    }
}

/// Cairn's six sizes by role, and nothing else.
enum TypeScale {
    static let micro = Font.system(size: 11)
    static let meta = Font.system(size: 12.5)
    static let ui = Font.system(size: 14)
    static let strong = Font.system(size: 18, design: .serif)
    static let title = Font.system(size: 22, design: .serif)
    static let display = Font.system(size: 30, design: .serif)

    /// The sentence under a page's title: what the backup will do.
    static let aim = Font.system(size: 16, design: .serif).italic()
    /// The one figure of the copying page.
    static let figure = Font.system(size: 64, design: .serif)
    /// A section's name inside a block: the meta size, medium, in the soft ink.
    /// Not uppercase with tracking, which is what every generic dashboard does.
    static let label = Font.system(size: 12.5, weight: .medium)
    static let group = Font.system(size: 11, weight: .medium)
    /// File names, patterns, numbers that line up.
    static let code = Font.system(size: 12.5, design: .monospaced)
    static let numbers = Font.system(size: 11, design: .monospaced)
}

enum Radius {
    static let nested: CGFloat = 7
    static let control: CGFloat = 10
    static let surface: CGFloat = 16
    static let sheet: CGFloat = 22
}
