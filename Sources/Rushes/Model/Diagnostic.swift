import Foundation

/// Aide › Décrire une carte…: a file a beta tester sends with what surprised
/// them, so a body Steven does not own can be added without having it in
/// hand (worksheet of 2026-10-01). It says what is on the card, every file
/// and folder with its size, dates and hidden flag, and what Rushes makes of
/// each: the shot it belongs to and its role, or why it stays on the card.
///
/// What it never holds: a byte of any picture, the volume's name or path
/// (a card renamed after a client would carry it), anything typed in the app,
/// or the body's serial number, only whether the camera writes one. The
/// card's own file names are the camera's (DSC01234, C0001).
///
/// It is made from the same scan as a backup, `CardScanner.scan` then
/// `dated`, so what it says is what the app would do, not a second opinion.
struct CardDiagnostic: Codable, Equatable {
    /// Bumped when a field changes meaning, so an old file is still read right.
    var format = 1
    var about = "Diagnostic de carte Rushes. Il décrit les fichiers de la carte (noms donnés par l'appareil, tailles, dates) et ce que Rushes en fait. Il ne contient aucune image, ni le nom du volume, ni rien de ce qui est tapé dans l'app."
    var made: String
    var rushes: String
    var macOS: String
    var timeZone: String
    var fileSystem: String?
    var looksLikeCard: Bool
    var brand: String
    var camera: Camera?
    var summary: Summary
    var kinds: [Kind]
    var groups: [Group]
    var entries: [Entry]

    struct Camera: Codable, Equatable {
        var name: String
        /// Whether the body writes a serial; the serial itself is not written.
        var hasSerial: Bool
    }

    struct Summary: Codable, Equatable {
        var photos: Int
        var videos: Int
        var sounds: Int
        var orphans: Int
        var unknown: Int
        var setAside: Int
        var unreadableFolders: [String]
        var bytes: Int64
        /// The models the photos' EXIF name, with how many shots each.
        var exifModels: [String: Int]
    }

    struct Kind: Codable, Equatable {
        var id: String
        var family: String
        var files: Int
        var bytes: Int64
        var copiedByDefault: Bool
        /// The tester's own setting when the file was made.
        var copiedHere: Bool
    }

    struct Group: Codable, Equatable {
        var key: String
        var category: String
        var anchor: String
        var files: Int
        /// EXIF DateTimeOriginal for a photo, the file system's date otherwise.
        var captureDate: String
        var exifModel: String?
    }

    /// What Rushes makes of one entry of the card.
    enum Fate: String, Codable, Equatable {
        case folder
        /// A camera's housekeeping (MISC, DATABASE…) or a hidden folder: walked, never copied.
        case setAsideFolder
        /// `._*`, `.Trashes`, `.Spotlight-V100`: the Mac's, skipped with what is inside.
        case macFile
        /// Windows' bin and index, Rushes' own records: not walked at all.
        case notWalked
        /// Part of a shot, copied if its kind is ticked.
        case shot
        /// A sidecar, proxy or thumbnail whose picture or clip is not on the card.
        case orphan
        /// A kind nobody listed: named under "Laissés sur la carte".
        case unknown
        /// A picture, clip or sound found in the housekeeping or hidden: makes the card "à vérifier".
        case setAside
        /// Anything else in the housekeeping or hidden: the camera's database, a preview.
        case housekeeping
        /// The Mac could not describe it: the card is one read in part.
        case unreadable
    }

    struct Entry: Codable, Equatable {
        var path: String
        var fate: Fate
        var size: Int64?
        var hidden: Bool
        var created: String?
        var modified: String?
        /// For a shot: its group's key, its role, and whether it names the group.
        var group: String?
        var role: String?
        var anchor: Bool?
        /// For a picture set aside: the folder that hid it, empty when the file itself is hidden.
        var hiddenBy: String?
    }
}

extension CardDiagnostic {
    /// Reads the card at `root` and describes it. Reads only; off the main thread.
    static func make(_ root: URL, settings: IngestSettings, now: Date = Date()) throws -> CardDiagnostic {
        let scan = CardScanner.dated(try CardScanner.scan(root))
        return describe(scan, entries: walk(root), settings: settings, now: now)
    }

    static func describe(_ scan: CardScan, entries walked: [Walked], settings: IngestSettings, now: Date) -> CardDiagnostic {
        var shots: [String: (group: String, role: FileRole, anchor: Bool)] = [:]
        for group in scan.groups {
            for file in group.files {
                shots[file.relativePath] = (group.key, file.role, file.relativePath == group.anchor.relativePath)
            }
        }
        let orphans = Set(scan.orphans.map(\.relativePath))
        let unknown = Set(scan.unknown.map(\.relativePath))
        let setAside = Dictionary(scan.setAside.map { ($0.relativePath, $0.hiddenBy ?? "") }, uniquingKeysWith: { a, _ in a })
        let unreadable = Set(scan.unreadableFolders)

        let entries = walked.map { item -> Entry in
            var entry = Entry(path: item.path, fate: item.fate, size: item.size, hidden: item.hidden,
                              created: item.created.map(stamp), modified: item.modified.map(stamp))
            if unreadable.contains(item.path) {
                entry.fate = .unreadable
            } else if item.fate == .shot {
                if let shot = shots[item.path] {
                    entry.group = shot.group
                    entry.role = shot.role.rawValue
                    entry.anchor = shot.anchor
                } else if orphans.contains(item.path) {
                    entry.fate = .orphan
                } else if unknown.contains(item.path) {
                    entry.fate = .unknown
                } else if let by = setAside[item.path] {
                    entry.fate = .setAside
                    entry.hiddenBy = by
                } else {
                    entry.fate = .housekeeping
                }
            }
            return entry
        }

        var kinds: [FileKind: Kind] = [:]
        for file in scan.groups.flatMap(\.files) + scan.orphans {
            let kind = file.kind
            var count = kinds[kind] ?? Kind(id: kind.id, family: "\(kind.family)", files: 0, bytes: 0,
                                            copiedByDefault: kind.includedByDefault, copiedHere: settings.includes(kind))
            count.files += 1
            count.bytes += file.size
            kinds[kind] = count
        }

        var models: [String: Int] = [:]
        for group in scan.groups {
            if let model = group.cameraModel { models[model, default: 0] += 1 }
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        return CardDiagnostic(
            made: stamp(now),
            rushes: Bundle.main.version,
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            timeZone: TimeZone.current.identifier,
            fileSystem: VolumeWatcher.fileSystem(of: scan.root),
            looksLikeCard: CardScanner.looksLikeCard(scan.root),
            brand: scan.brand.rawValue,
            camera: scan.camera.map { Camera(name: $0.name, hasSerial: $0.serial != nil) },
            summary: Summary(
                photos: scan.photoCount, videos: scan.videoCount, sounds: scan.audioCount,
                orphans: scan.orphans.count, unknown: scan.unknown.count, setAside: scan.setAside.count,
                unreadableFolders: scan.unreadableFolders, bytes: scan.totalSize, exifModels: models
            ),
            kinds: kinds.sorted { $0.key.order < $1.key.order }.map(\.value),
            groups: scan.groups.map { group in
                Group(key: group.key, category: group.category.rawValue, anchor: group.anchor.relativePath,
                      files: group.files.count, captureDate: stamp(group.captureDate), exifModel: group.cameraModel)
            },
            entries: entries
        )
    }

    /// One entry as the walk found it, before the scan says what it is.
    struct Walked: Sendable {
        var path: String
        /// `.shot` stands for "a file the scanner classified", refined by `describe`.
        var fate: Fate
        var size: Int64?
        var hidden: Bool
        var created: Date?
        var modified: Date?
    }

    /// Every entry of the card, in the walk's own order, with the scanner's
    /// rules for what is skipped. Dot entries are named, not entered.
    static func walk(_ root: URL) -> [Walked] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let rootDepth = root.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return [] }
        var found: [Walked] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let path = url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                found.append(Walked(path: path, fate: .unreadable, hidden: false))
                continue
            }
            let folder = values.isDirectory == true
            var item = Walked(path: path, fate: .folder, size: folder ? nil : Int64(values.fileSize ?? 0),
                              hidden: values.isHidden == true && !name.hasPrefix("."),
                              created: values.creationDate, modified: values.contentModificationDate)
            let upper = name.uppercased()
            if name.hasPrefix(".") {
                item.fate = .macFile
                if folder { walker.skipDescendants() }
            } else if folder {
                if MediaTypes.ignoredFolders.contains(upper) {
                    item.fate = .notWalked
                    walker.skipDescendants()
                } else if MediaTypes.skippedFolders.contains(upper) || values.isHidden == true {
                    item.fate = .setAsideFolder
                }
            } else {
                // A file: `describe` says what it is, from the scan itself,
                // so the diagnostic never holds a second opinion.
                item.fate = .shot
            }
            found.append(item)
        }
        return found
    }

    /// Local wall-clock time with its offset, the way the camera's clock is read.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func read(_ data: Data) throws -> CardDiagnostic {
        try JSONDecoder().decode(CardDiagnostic.self, from: data)
    }

    /// "diagnostic-sony-261001-1420.json"
    var suggestedFileName: String {
        let brand = brand.lowercased().filter { $0.isLetter || $0.isNumber }
        let digits = made.filter(\.isNumber)
        let stampPart = digits.count >= 12 ? "\(digits.dropFirst(2).prefix(6))-\(digits.dropFirst(8).prefix(4))" : "carte"
        return "diagnostic-\(brand.isEmpty ? "carte" : brand)-\(stampPart).json"
    }
}
