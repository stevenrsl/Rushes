import Foundation

/// What Rushes remembers from one night to the next. Kept as JSON in the
/// user defaults; a key added later decodes to its default.
///
/// A default that changes in the code does not reach settings already saved:
/// they hold the old value, written the first time anything was changed. So
/// each change that has to travel gets a number in `schema` and a line in
/// `migrate`, applied once, the next time Rushes opens.
struct IngestSettings: Codable, Hashable, Sendable {
    // Defaults are Steven's own way of working (2026-09-22). Nothing personal
    // is written in: the initials are typed once and kept.
    var initials = ""
    var client = ""
    var project = ""
    var namePattern = NamePreset.cameraLast.pattern
    var folderPattern = IngestSettings.defaultFolderPattern
    var layout = FolderLayout.byType
    /// 4 is the `000x` of the model.
    var padding = 4
    /// Until this hour, a shot belongs to the day before.
    var dayCutoffHour = 5
    /// One count for photos and videos, in the order they were shot.
    var sharedCounter = false
    /// Kinds ticked or unticked by hand, by `FileKind.id`. A kind never
    /// touched follows `FileKind.includedByDefault`.
    var kindChoices: [String: Bool] = [:]
    /// On since 2026-09-22, when skipping stopped meaning "the record says so"
    /// and started meaning "the file is still on every drive, at its size".
    /// Off, a card kept for a five day shoot is copied again every night under
    /// new numbers.
    var skipAlreadyCopied = true
    var ejectWhenDone = true
    var appearance = Appearance.system
    /// Letters chosen by hand, by camera.
    var cameras: [KnownCamera] = []
    /// Paths of the drives last used, first one first.
    var destinations: [String] = []
    var recentClients: [String] = []
    var recentProjects: [String] = []
    /// What was saved knows which changes it has already seen. Settings
    /// written before this existed read as 0.
    var schema = IngestSettings.schema

    /// 1: everything up to 2026-09-21. 2: skipping what is already saved.
    static let schema = 2

    static let defaultFolderPattern = "{YYMMDD}_{CLIENT}_{PROJET}"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IngestSettings()
        initials = try c.decodeIfPresent(String.self, forKey: .initials) ?? d.initials
        client = try c.decodeIfPresent(String.self, forKey: .client) ?? d.client
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? d.project
        namePattern = try c.decodeIfPresent(String.self, forKey: .namePattern) ?? d.namePattern
        folderPattern = try c.decodeIfPresent(String.self, forKey: .folderPattern) ?? d.folderPattern
        layout = try c.decodeIfPresent(FolderLayout.self, forKey: .layout) ?? d.layout
        padding = try c.decodeIfPresent(Int.self, forKey: .padding) ?? d.padding
        dayCutoffHour = try c.decodeIfPresent(Int.self, forKey: .dayCutoffHour) ?? d.dayCutoffHour
        sharedCounter = try c.decodeIfPresent(Bool.self, forKey: .sharedCounter) ?? d.sharedCounter
        kindChoices = try c.decodeIfPresent([String: Bool].self, forKey: .kindChoices) ?? d.kindChoices
        skipAlreadyCopied = try c.decodeIfPresent(Bool.self, forKey: .skipAlreadyCopied) ?? d.skipAlreadyCopied
        ejectWhenDone = try c.decodeIfPresent(Bool.self, forKey: .ejectWhenDone) ?? d.ejectWhenDone
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        cameras = try c.decodeIfPresent([KnownCamera].self, forKey: .cameras) ?? d.cameras
        destinations = try c.decodeIfPresent([String].self, forKey: .destinations) ?? d.destinations
        recentClients = try c.decodeIfPresent([String].self, forKey: .recentClients) ?? d.recentClients
        recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? d.recentProjects
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 0
    }

    /// Brings settings written by an older Rushes up to date, and says whether
    /// anything moved. A change is listed here only when leaving the old value
    /// in place would be wrong, never to undo a choice someone made on purpose.
    mutating func migrate() -> Bool {
        guard schema < Self.schema else { return false }
        // 2 (2026-09-22): skipping a shot stopped meaning "a record lists it"
        // and started meaning "it is on every drive, at its size". Steven had
        // turned the old one off because a record proves nothing, which the
        // new one answers, so the setting goes on wherever it was left off.
        if schema < 2 { skipAlreadyCopied = true }
        schema = Self.schema
        return true
    }

    /// Night is the use; the Mac may still be set to light at 3 in the morning.
    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, dark, light
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Comme le Mac"
            case .dark: "Toujours sombre"
            case .light: "Toujours clair"
            }
        }
    }

    func includes(_ kind: FileKind) -> Bool {
        kindChoices[kind.id] ?? kind.includedByDefault
    }

    static let storageKey = "settings"

    static func load(from defaults: UserDefaults = .standard) -> IngestSettings {
        guard let data = defaults.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(IngestSettings.self, from: data)
        else { return IngestSettings() }
        // Written back at once, so a migration runs once and an answer given
        // afterwards is the one that stands.
        if settings.migrate() { settings.save(to: defaults) }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Puts a value at the head of a recents list, eight at most.
    static func remembering(_ value: String, in list: [String]) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        return Array(([trimmed] + list.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }).prefix(8))
    }
}
