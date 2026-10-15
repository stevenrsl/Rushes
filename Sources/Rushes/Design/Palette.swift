import AppKit
import Observation
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

    // MARK: Ambiance

    /// The tokens of the ambiance chosen in Réglages › Apparence. Reading
    /// `Theme.shared` here is what redraws a view when it changes: the views
    /// that use a colour are the ones Observation tracks.
    private static var current: Tokens {
        let ambiance = Theme.shared.ambiance
        if let made = made[ambiance] { return made }
        let tokens = Tokens(ambiance)
        made[ambiance] = tokens
        return tokens
    }

    /// Made once per ambiance: a dynamic colour is an object, and a page asks
    /// for hundreds of them per redraw. Only the main thread draws.
    private static var made: [Ambiance: Tokens] = [:]

    // MARK: Ground and ink

    /// Wool with a breath of lichen. The forest at night in dark.
    static var ground: Color { current.ground }
    /// The cards' column: a shade deeper, as Cairn's sidebar is.
    static var groundSunk: Color { current.groundSunk }
    /// A block on the page, a sheet, a popover: paler ivory.
    static var surface: Color { current.surface }
    static var surfaceRaised: Color { current.surfaceRaised }

    /// Pine slate.
    static var ink: Color { current.ink }
    static var inkSoft: Color { current.inkSoft }
    static var inkFaint: Color { current.inkFaint }

    static var hairline: Color { current.hairline }
    static var hairlineStrong: Color { current.hairlineStrong }

    /// The row under the pointer, a wash of ink.
    static var hover: Color { current.hover }

    // MARK: The forest, in pastel

    /// Pastel sage: the one button, a chosen chip, a ticked kind. Always with
    /// `onAccent` on it, and a hairline of `accentLine` to hold its shape on
    /// the pale ground.
    static var accent: Color { current.accent }
    static var onAccent: Color { current.onAccent }
    /// The deep forest that writes: links, "déjà sauvegardé", a checked mark.
    /// 6.13:1 on the ground in light, 10.74:1 in dark.
    static var accentInk: Color { current.accentInk }
    /// The green that draws: bars, strokes, a checkbox's edge.
    static var accentLine: Color { current.accentLine }
    /// Paler still: the naming example, a selected row.
    static var accentSoft: Color { current.accentSoft }

    /// The top of the page, the forest fading into the ground.
    static var wash: [Color] { current.wash }

    /// Every token of one ambiance. The forest is the original, number for
    /// number; the others move its hues and keep its lightness, which is what
    /// the contrasts depend on. Each was measured as the forest was (2026-10-15):
    /// `inkFaint` on `groundSunk` 4.64:1 at worst, `alert` on `groundSunk`
    /// 4.50:1, `accentInk` on the ground 6.13:1, `onAccent` on `accent` 9:1,
    /// bars against their track 3.17:1, all within sRGB.
    struct Tokens {
        let ground, groundSunk, surface, surfaceRaised: Color
        let ink, inkSoft, inkFaint, hairline, hairlineStrong, hover: Color
        let accent, onAccent, accentInk, accentLine, accentSoft: Color
        let wash: [Color]

        init(_ ambiance: Ambiance) {
            let t = ambiance.tone
            // a: the accent's hue. g: the paper's by day. n: the ground's at
            // night. c: how much colour the accent carries, k the neutrals.
            let a = t.accent, g = t.paper, n = t.night, c = t.chroma, k = t.neutral
            ground = Palette.dynamic(Palette.oklch(0.962, 0.011 * k, g), Palette.oklch(0.195, 0.014 * k, n))
            groundSunk = Palette.dynamic(Palette.oklch(0.936, 0.015 * k, g + 4), Palette.oklch(0.165, 0.013 * k, n))
            surface = Palette.dynamic(Palette.oklch(0.988, 0.006 * k, g - 13), Palette.oklch(0.232, 0.015 * k, n))
            surfaceRaised = Palette.dynamic(Palette.oklch(0.997, 0.003 * k, g - 18), Palette.oklch(0.268, 0.016 * k, n))

            ink = Palette.dynamic(Palette.oklch(0.25, 0.020 * k, a + 10), Palette.oklch(0.94, 0.010 * k, g - 8))
            inkSoft = Palette.dynamic(Palette.oklch(0.44, 0.020 * k, a + 10), Palette.oklch(0.77, 0.014 * k, g + 12))
            inkFaint = Palette.dynamic(Palette.oklch(0.515, 0.018 * k, a + 5), Palette.oklch(0.655, 0.014 * k, g + 22))
            hairline = Palette.dynamic(Palette.oklch(0.885, 0.014 * k, g + 2), Palette.oklch(0.31, 0.014 * k, n))
            hairlineStrong = Palette.dynamic(Palette.oklch(0.82, 0.016 * k, g + 7), Palette.oklch(0.40, 0.015 * k, n))
            hover = Palette.dynamic(Palette.oklch(0.25, 0.020 * k, a + 10, 0.05), Palette.oklch(0.94, 0.010 * k, g - 8, 0.06))

            accent = Palette.dynamic(Palette.oklch(0.865, 0.055 * c, a), Palette.oklch(0.80, 0.070 * c, a))
            onAccent = Palette.dynamic(Palette.oklch(0.30, 0.045 * c, a + 5), Palette.oklch(0.20, 0.030 * c, a + 5))
            accentInk = Palette.dynamic(Palette.oklch(0.46, 0.085 * c, a + 5), Palette.oklch(0.82, 0.075 * c, a))
            accentLine = Palette.dynamic(Palette.oklch(0.56, 0.090 * c, a + 2), Palette.oklch(0.70, 0.085 * c, a))
            accentSoft = Palette.dynamic(Palette.oklch(0.935, 0.028 * c, a), Palette.oklch(0.30, 0.035 * c, a + 5))
            wash = [
                Palette.dynamic(Palette.oklch(0.88, 0.045 * c, a, 0.35), Palette.oklch(0.55, 0.060 * c, a + 5, 0.12)),
                Palette.dynamic(Palette.oklch(0.962, 0.011 * k, g, 0), Palette.oklch(0.195, 0.014 * k, n, 0)),
            ]
        }
    }

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

/// Cairn's six sizes by role, and nothing else. The titles are in serif
/// unless the ambiance says sans (Réglages › Apparence).
enum TypeScale {
    static let micro = Font.system(size: 11)
    static let meta = Font.system(size: 12.5)
    static let ui = Font.system(size: 14)
    static var strong: Font { Font.system(size: 18, design: titles) }
    static var title: Font { Font.system(size: 22, design: titles) }
    static var display: Font { Font.system(size: 30, design: titles) }

    /// The sentence under a page's title: what the backup will do.
    static var aim: Font { Font.system(size: 16, design: titles).italic() }
    /// The one figure of the copying page.
    static var figure: Font { Font.system(size: 64, design: titles) }

    private static var titles: Font.Design { Theme.shared.titles == .serif ? .serif : .default }
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

// MARK: - The ambiance

/// What Réglages › Apparence chose, read by `Palette` and `TypeScale` while a
/// view draws, so changing it redraws every window at once. `Ingest` keeps it
/// equal to the settings.
@Observable
final class Theme {
    static let shared = Theme()
    var ambiance = Ambiance.forest
    var titles = TitleFace.serif
}

/// A set of hues for the whole app, asked for by Steven on 2026-10-15 ("custom
/// l'ambiance graphique"). Presets rather than a colour picker: a pastel picked
/// by hand cannot be promised to carry text, and these were all measured. The
/// signals (`late`, `alert`) and the camera hues stay what they are in every
/// one, so a warning reads the same whatever the ambiance; none of the accents
/// sits near their peat and sea thrift.
enum Ambiance: String, Codable, CaseIterable, Identifiable, Sendable {
    case forest, ocean, lavender, slate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forest: "Forêt"
        case .ocean: "Océan"
        case .lavender: "Lavande"
        case .slate: "Ardoise"
        }
    }

    var detail: String {
        switch self {
        case .forest: "Sauge pastel sur de la laine, l'ambiance d'origine."
        case .ocean: "Bleu d'eau sur un papier froid."
        case .lavender: "Lavande sur un papier crème."
        case .slate: "Presque sans couleur, un gris bleuté."
        }
    }

    /// The hues and how much colour: see `Palette.Tokens`.
    var tone: (accent: Double, paper: Double, night: Double, chroma: Double, neutral: Double) {
        switch self {
        case .forest: (150, 118, 165, 1, 1)
        case .ocean: (230, 215, 240, 1, 1)
        case .lavender: (300, 80, 290, 0.8, 0.8)
        case .slate: (255, 250, 255, 0.35, 0.5)
        }
    }
}

/// Titles in New York, as Cairn's, or in the system's sans.
enum TitleFace: String, Codable, CaseIterable, Identifiable, Sendable {
    case serif, sans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: "Avec empattements"
        case .sans: "Sans empattements"
        }
    }
}
