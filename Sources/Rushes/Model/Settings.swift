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
    /// What happens to the cards told "formatable": ejected, as Steven
    /// works, left in the reader, or offered a format from the done page.
    /// Saved before 2026-10-15 as `ejectWhenDone`, still read.
    var whenDone = WhenDone.eject
    var appearance = Appearance.system
    /// The hues of the whole app, and the face of its titles.
    var ambiance = Ambiance.forest
    var titles = TitleFace.serif
    /// Letters chosen by hand, by camera.
    var cameras: [KnownCamera] = []
    /// Paths of the drives last used, first one first.
    var destinations: [String] = []
    /// What each destination receives, by path, when it is not everything:
    /// the photos on one disk and the videos on another, or in two folders
    /// of one (asked 2026-10-16 for 0.6). A path not listed takes it all.
    var destinationKinds: [String: [MediaCategory]] = [:]
    var recentClients: [String] = []
    var recentProjects: [String] = []
    /// Bytes read and read back per second over the last backup worth
    /// measuring, cards and drives together: what "fini vers 4 h 10" is
    /// worked out from before ⌘↩. Zero until one has run.
    var measuredThroughput: Double = 0
    /// An ASC MHL beside each shoot, for a DIT or a post house. Off: it is
    /// one more folder in every shoot, which a solo shooter may never open.
    var writeMHL = false
    /// A copy sent once the backup is verified: a cloud folder or an FTP
    /// server. None by default. Its password is in the keychain, never here.
    var upload = UploadTarget()
    /// Sends by itself at the end of a backup. Off: a button on the done page.
    var uploadWhenDone = false
    /// Name patterns saved under a name of one's own, beside the built-in
    /// presets (asked 2026-10-16): one per client who wants theirs.
    var namePresets: [SavedNamePreset] = []
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
        if let when = try c.decodeIfPresent(WhenDone.self, forKey: .whenDone) {
            whenDone = when
        } else if let eject = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .ejectWhenDone) {
            whenDone = eject ? .eject : .keep
        }
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        ambiance = try c.decodeIfPresent(Ambiance.self, forKey: .ambiance) ?? d.ambiance
        titles = try c.decodeIfPresent(TitleFace.self, forKey: .titles) ?? d.titles
        cameras = try c.decodeIfPresent([KnownCamera].self, forKey: .cameras) ?? d.cameras
        destinations = try c.decodeIfPresent([String].self, forKey: .destinations) ?? d.destinations
        destinationKinds = try c.decodeIfPresent([String: [MediaCategory]].self, forKey: .destinationKinds) ?? d.destinationKinds
        recentClients = try c.decodeIfPresent([String].self, forKey: .recentClients) ?? d.recentClients
        recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? d.recentProjects
        measuredThroughput = try c.decodeIfPresent(Double.self, forKey: .measuredThroughput) ?? d.measuredThroughput
        writeMHL = try c.decodeIfPresent(Bool.self, forKey: .writeMHL) ?? d.writeMHL
        upload = try c.decodeIfPresent(UploadTarget.self, forKey: .upload) ?? d.upload
        uploadWhenDone = try c.decodeIfPresent(Bool.self, forKey: .uploadWhenDone) ?? d.uploadWhenDone
        namePresets = try c.decodeIfPresent([SavedNamePreset].self, forKey: .namePresets) ?? d.namePresets
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

    /// Keys no longer written, read so an older choice is kept.
    private enum LegacyKeys: String, CodingKey {
        case ejectWhenDone
    }

    /// The cards that may be formatted, once the backup is verified. A card
    /// told "ne pas formater" is never ejected nor offered a format, whatever
    /// this says.
    enum WhenDone: String, Codable, CaseIterable, Identifiable, Sendable {
        case eject, keep, offerFormat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .eject: "Les éjecter"
            case .keep: "Les laisser branchées"
            case .offerFormat: "Proposer de les formater ou de les vider"
            }
        }
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

    /// Saves the pattern under a name; a name already used takes the new
    /// pattern, a pattern already saved takes the new name. Says the name
    /// kept, or nil when there is nothing to save.
    @discardableResult
    mutating func savePreset(named name: String, pattern: String) -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !pattern.isEmpty, NamePreset.matching(pattern) == nil else { return nil }
        let place = namePresets.firstIndex { $0.pattern == pattern }
            ?? namePresets.firstIndex { $0.name.caseInsensitiveCompare(title) == .orderedSame }
            ?? namePresets.count
        namePresets.insert(SavedNamePreset(name: title, pattern: pattern), at: place)
        // A rename keeps its place; whatever else held that name or that
        // pattern goes.
        namePresets = namePresets.enumerated().filter { i, kept in
            i == place || (kept.pattern != pattern && kept.name.caseInsensitiveCompare(title) != .orderedSame)
        }.map(\.element)
        return title
    }

    /// Whether a plan made with these settings would be the one made with
    /// `other`. A change it never reads (the ambiance, the recents, a preset
    /// saved, the pace of last night) makes no new plan: on a card of ten
    /// thousand shots each one cost a walk of the drives and a page redrawn.
    func plansLike(_ other: IngestSettings) -> Bool {
        initials == other.initials && client == other.client && project == other.project
            && namePattern == other.namePattern && folderPattern == other.folderPattern
            && layout == other.layout && padding == other.padding && dayCutoffHour == other.dayCutoffHour
            && sharedCounter == other.sharedCounter && kindChoices == other.kindChoices
            && skipAlreadyCopied == other.skipAlreadyCopied && writeMHL == other.writeMHL
            && destinations == other.destinations && destinationKinds == other.destinationKinds
    }

    /// What a destination receives.
    func receives(_ path: String) -> Set<MediaCategory> {
        guard let kinds = destinationKinds[path], !kinds.isEmpty else { return Set(MediaCategory.allCases) }
        return Set(kinds)
    }

    /// Sets what a destination receives; everything is stored as nothing, so
    /// a drive added later and a drive set back look the same. Never empty: a
    /// destination that receives nothing is one to remove.
    mutating func setReceives(_ path: String, _ kinds: Set<MediaCategory>) {
        guard !kinds.isEmpty else { return }
        destinationKinds[path] = kinds.count == MediaCategory.allCases.count
            ? nil
            : MediaCategory.allCases.filter(kinds.contains)
    }

    /// Whether any destination is limited to some kinds.
    var routes: Bool { destinations.contains { receives($0).count < MediaCategory.allCases.count } }

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

/// A name pattern kept under a name of one's own.
struct SavedNamePreset: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var pattern: String
    var id: String { pattern }
}
