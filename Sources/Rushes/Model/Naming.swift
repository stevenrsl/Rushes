import Foundation

/// The day a shoot belongs to. A night shoot does not change day at midnight:
/// with the cutoff at 5 h, a photo taken at 02:40 on the 22nd belongs to the
/// 21st, the day the shoot started. Steven comes home at 3 in the morning.
struct ShootDay: Codable, Hashable, Sendable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, cutoffHour: Int, calendar: Calendar = .current) {
        let shifted = calendar.date(byAdding: .hour, value: -cutoffHour, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Noon that day, for a date picker.
    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    var yymmdd: String { String(format: "%02d%02d%02d", year % 100, month, day) }
    var yyyymmdd: String { String(format: "%04d%02d%02d", year, month, day) }

    static func < (a: ShootDay, b: ShootDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// The pieces a name is made of. Written between braces in a pattern.
enum NameToken: String, CaseIterable, Sendable {
    case yymmdd = "YYMMDD"
    case yyyymmdd = "YYYYMMDD"
    case time = "HHMMSS"
    case initials = "INIT"
    case client = "CLIENT"
    case project = "PROJET"
    case camera = "CAM"
    case number = "NUM"
    case original = "ORIG"
    case type = "TYPE"

    /// Other spellings a person might type, accepted and kept as typed.
    static let aliases: [String: NameToken] = [
        "DATE": .yymmdd, "AAMMJJ": .yymmdd, "AAAAMMJJ": .yyyymmdd, "HEURE": .time,
        "INITIALES": .initials, "PROJECT": .project, "CAMERA": .camera, "N": .number,
        "NUMERO": .number, "ORIGINAL": .original,
    ]

    var label: String {
        switch self {
        case .yymmdd: "Date"
        case .yyyymmdd: "Date longue"
        case .time: "Heure"
        case .initials: "Initiales"
        case .client: "Client"
        case .project: "Projet"
        case .camera: "Caméra"
        case .number: "Numéro"
        case .original: "Nom d'origine"
        case .type: "Type"
        }
    }

    var help: String {
        switch self {
        case .yymmdd: "260921 : jour du tournage"
        case .yyyymmdd: "20260921"
        case .time: "234107 : heure de la prise"
        case .initials: "Tes initiales"
        case .client: "Le client"
        case .project: "Le projet"
        case .camera: "La lettre de la carte : A, B…"
        case .number: "0001, 0002… une photo et son RAW partagent le même"
        case .original: "DSC01234 : le nom donné par l'appareil"
        case .type: "PHOTO, VIDEO ou AUDIO"
        }
    }

    /// Tokens whose value comes from the person and must be filled in.
    var isTyped: Bool { self == .initials || self == .client || self == .project || self == .camera }
}

/// What the tokens of one shot are worth.
struct NameValues: Sendable {
    var day: ShootDay
    var time: String = "000000"
    var initials: String = ""
    var client: String = ""
    var project: String = ""
    var camera: String = ""
    var original: String = ""
    var type: String = ""
    var number: Int?
    var padding: Int = 4

    func value(of token: NameToken) -> String {
        switch token {
        case .yymmdd: day.yymmdd
        case .yyyymmdd: day.yyyymmdd
        case .time: time
        case .initials: initials
        case .client: client
        case .project: project
        case .camera: camera
        case .number: number.map { String(format: "%0\(padding)d", $0) } ?? String(repeating: "0", count: padding)
        case .original: original
        case .type: type
        }
    }
}

/// A pattern like `{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}`. Anything outside
/// braces is kept as typed; a brace pair that names no token is kept too.
struct NameTemplate: Hashable, Sendable {
    enum Part: Hashable, Sendable {
        case literal(String)
        case token(NameToken)
    }

    let pattern: String
    let parts: [Part]

    init(_ pattern: String) {
        self.pattern = pattern
        var parts: [Part] = []
        var literal = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let name = rest[rest.index(after: open)..<close].uppercased()
            if let token = NameToken(rawValue: name) ?? NameToken.aliases[name] {
                if !literal.isEmpty { parts.append(.literal(literal)) }
                literal = ""
                parts.append(.token(token))
            } else {
                literal += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        if !literal.isEmpty { parts.append(.literal(literal)) }
        self.parts = parts
    }

    var tokens: [NameToken] {
        parts.compactMap { if case .token(let t) = $0 { t } else { nil } }
    }

    func uses(_ token: NameToken) -> Bool { tokens.contains(token) }

    /// A name that stays apart from every other shot needs a number, or the
    /// camera's own name.
    var isUnique: Bool { uses(.number) || uses(.original) }

    func render(_ values: NameValues) -> String {
        let raw = parts.map { part in
            switch part {
            case .literal(let text): Sanitize.fileName(text)
            case .token(let token): Sanitize.fileName(values.value(of: token))
            }
        }.joined()
        return Sanitize.collapse(raw)
    }

    /// A folder pattern may hold slashes: each piece is one folder.
    func renderPath(_ values: NameValues) -> String {
        pattern.split(separator: "/", omittingEmptySubsequences: true)
            .map { NameTemplate(String($0)).render(values) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Matches names this pattern made for the same day, client and project,
    /// and captures their number, so a second card carries on where the first
    /// stopped instead of starting again at 0001.
    func counterExpression(_ values: NameValues) -> NSRegularExpression? {
        guard uses(.number) else { return nil }
        let source = parts.map { part -> String in
            switch part {
            case .literal(let text): return NSRegularExpression.escapedPattern(for: Sanitize.fileName(text))
            case .token(.number): return "(\\d+)"
            case .token(.original): return ".+"
            case .token(.time): return "\\d{6}"
            case .token(let token): return NSRegularExpression.escapedPattern(for: Sanitize.fileName(values.value(of: token)))
            }
        }.joined()
        return try? NSRegularExpression(pattern: "^" + source + "$", options: [.caseInsensitive])
    }

    /// What two shots share when they count from the same number: the name
    /// with the number, the time and the original name left out.
    func counterScope(_ values: NameValues) -> String {
        parts.map { part -> String in
            switch part {
            case .literal(let text): return text
            case .token(.number), .token(.original), .token(.time): return "\u{1}"
            case .token(let token): return values.value(of: token)
            }
        }.joined().lowercased()
    }
}

enum NamePreset: String, CaseIterable, Identifiable, Sendable {
    case cameraLast
    case standard
    case multicam
    case original
    case longDate

    var id: String { rawValue }

    var pattern: String {
        switch self {
        case .cameraLast: "{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}_{CAM}"
        case .standard: "{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}"
        case .multicam: "{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{CAM}{NUM}"
        case .original: "{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}_{ORIG}"
        case .longDate: "{YYYYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}"
        }
    }

    var title: String {
        switch self {
        case .cameraLast: "Caméra au bout"
        case .standard: "Standard"
        case .multicam: "Multicam"
        case .original: "Avec le nom d'origine"
        case .longDate: "Année complète"
        }
    }

    var detail: String {
        switch self {
        case .cameraLast: "La lettre de la carte après le numéro : 0001_A, 0001_D."
        case .standard: "Le modèle de base, sans caméra."
        case .multicam: "La lettre de chaque carte devant le numéro : A0001, B0001."
        case .original: "Garde le nom de l'appareil au bout, pour retrouver un fichier cité par un client."
        case .longDate: "La date sur huit chiffres."
        }
    }

    static func matching(_ pattern: String) -> NamePreset? {
        allCases.first { $0.pattern == pattern }
    }
}

enum Sanitize {
    /// A client or a project as it goes in a name: ASCII letters, digits and
    /// underscores as typed, every run of anything else a single hyphen.
    /// "Café d'Été" → "Cafe-dEte", "RX_500h" → "RX_500h", "Kaffi_Lexus RX" →
    /// "Kaffi_Lexus-RX". Steven wanted the underscore kept when he types one
    /// (2026-09-21): nothing reads a name back by splitting it, so it costs
    /// nothing. Accents are gone because the files travel to servers, editing
    /// suites and clients' Windows machines.
    static func field(_ text: String) -> String {
        let latin = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? text
        var out = ""
        var pendingDash = false
        for character in latin {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty, out.last != "_" { out.append("-") }
                pendingDash = false
                out.append(character)
            } else if character == "_" {
                // "RX _ 500h" is RX_500h: the underscore swallows the spaces around it.
                if !out.isEmpty, out.last != "_" { out.append("_") }
                pendingDash = false
            } else if character == "'" || character == "’" || character == "`" {
                continue
            } else {
                pendingDash = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    /// Initials and camera letters: letters and digits only, upper case.
    static func code(_ text: String) -> String {
        field(text).filter { $0 != "-" && $0 != "_" }.uppercased()
    }

    /// What no file name may hold on a Mac, on exFAT or on Windows.
    static func fileName(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        return String(text.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
    }

    /// An empty field leaves its separators behind: `260921_SR__0001` becomes
    /// `260921_SR_0001`, and nothing starts or ends with one.
    static func collapse(_ name: String) -> String {
        var out = name
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_- ."))
        return out
    }
}

/// Where each kind of file goes inside the shoot's folder: one path per kind
/// of picture, clip or sound, with the same tokens as the name and « / » for
/// a subfolder. `VIDEO/{CAM}` puts each camera's clips apart. Empty: straight
/// in the shoot's folder. Sidecars and thumbnails go where their anchor goes,
/// so an XMP sits beside its RAW and an XML beside its clip.
struct FolderLayout: Codable, Hashable, Sendable {
    var raw: String
    var jpeg: String
    var heif: String
    var video: String
    var proxy: String
    var audio: String

    init(raw: String, jpeg: String, heif: String, video: String, proxy: String, audio: String) {
        self.raw = raw
        self.jpeg = jpeg
        self.heif = heif
        self.video = video
        self.proxy = proxy
        self.audio = audio
    }

    static let byType = FolderPreset.byType.layout

    /// The first version kept one of three fixed layouts by name
    /// ("byType", "typeOnly", "flat"): read as the preset it was.
    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = (FolderPreset(rawValue: name) ?? .byType).layout
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.byType
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? d.raw
        jpeg = try c.decodeIfPresent(String.self, forKey: .jpeg) ?? d.jpeg
        heif = try c.decodeIfPresent(String.self, forKey: .heif) ?? d.heif
        video = try c.decodeIfPresent(String.self, forKey: .video) ?? d.video
        proxy = try c.decodeIfPresent(String.self, forKey: .proxy) ?? d.proxy
        audio = try c.decodeIfPresent(String.self, forKey: .audio) ?? d.audio
    }

    /// The pattern of each kind that has a folder of its own, in the order
    /// the settings show them.
    static let roles: [FileRole] = [.raw, .jpeg, .heif, .video, .proxy, .audio]

    subscript(role: FileRole) -> String {
        get {
            switch role {
            case .raw: raw
            case .jpeg: jpeg
            case .heif: heif
            case .video: video
            case .proxy: proxy
            case .audio: audio
            case .sidecar, .thumbnail: ""
            }
        }
        set {
            switch role {
            case .raw: raw = newValue
            case .jpeg: jpeg = newValue
            case .heif: heif = newValue
            case .video: video = newValue
            case .proxy: proxy = newValue
            case .audio: audio = newValue
            case .sidecar, .thumbnail: break
            }
        }
    }

    func uses(_ token: NameToken) -> Bool {
        Self.roles.contains { NameTemplate(self[$0]).uses(token) }
    }

    func folder(for role: FileRole, anchor: FileRole, values: NameValues) -> String {
        switch role {
        case .sidecar, .thumbnail:
            return anchor.isPrimary ? folder(for: anchor, anchor: anchor, values: values) : ""
        default:
            return NameTemplate(self[role]).renderPath(values)
        }
    }
}

enum FolderPreset: String, CaseIterable, Identifiable, Sendable {
    case byType
    case byCamera
    case photoVideo
    case typeOnly
    case flat

    var id: String { rawValue }

    var layout: FolderLayout {
        switch self {
        case .byType:
            FolderLayout(raw: "PHOTO/RAW", jpeg: "PHOTO/JPG", heif: "PHOTO/HEIF", video: "VIDEO", proxy: "VIDEO/PROXY", audio: "AUDIO")
        case .byCamera:
            FolderLayout(raw: "PHOTO/{CAM}/RAW", jpeg: "PHOTO/{CAM}/JPG", heif: "PHOTO/{CAM}/HEIF", video: "VIDEO/{CAM}", proxy: "VIDEO/{CAM}/PROXY", audio: "AUDIO")
        case .photoVideo:
            FolderLayout(raw: "PHOTO", jpeg: "PHOTO", heif: "PHOTO", video: "VIDEO", proxy: "VIDEO/PROXY", audio: "AUDIO")
        case .typeOnly:
            FolderLayout(raw: "RAW", jpeg: "JPG", heif: "HEIF", video: "VIDEO", proxy: "PROXY", audio: "AUDIO")
        case .flat:
            FolderLayout(raw: "", jpeg: "", heif: "", video: "", proxy: "", audio: "")
        }
    }

    var title: String {
        switch self {
        case .byType: "Par type"
        case .byCamera: "Par caméra"
        case .photoVideo: "Photo et vidéo"
        case .typeOnly: "Sans PHOTO/"
        case .flat: "Tout ensemble"
        }
    }

    var detail: String {
        switch self {
        case .byType: "PHOTO/RAW, PHOTO/JPG, VIDEO, VIDEO/PROXY, AUDIO."
        case .byCamera: "La lettre de chaque carte en sous-dossier : VIDEO/A, VIDEO/D, PHOTO/A/RAW."
        case .photoVideo: "Le RAW et son JPEG côte à côte dans PHOTO, les clips dans VIDEO."
        case .typeOnly: "RAW, JPG, VIDEO, PROXY et AUDIO au premier niveau."
        case .flat: "Tous les fichiers directement dans le dossier du tournage."
        }
    }

    static func matching(_ layout: FolderLayout) -> FolderPreset? {
        allCases.first { $0.layout == layout }
    }
}

/// Shoot folders people ask for, offered beside the field.
enum ShootFolderPresets {
    static let patterns = [
        IngestSettings.defaultFolderPattern,
        "{CLIENT}/{YYMMDD}_{PROJET}",
        "{CLIENT}/{PROJET}/{YYMMDD}",
        "{YYYYMMDD}_{CLIENT}_{PROJET}",
        "",
    ]
}
