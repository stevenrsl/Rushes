import Foundation

/// One card as the planner sees it.
struct PlanSource: Sendable {
    let id: String
    let volumeName: String
    /// A, B, C: the `{CAM}` of the name.
    let cameraLabel: String
    let groups: [MediaGroup]
}

struct PlannedFile: Identifiable, Hashable, Sendable {
    let file: MediaFile
    /// From the drive's root: `260921_Kaffi_Lexus/PHOTO/RAW/260921_SR_Kaffi_Lexus_0001.ARW`.
    let relativePath: String
    var id: String { file.id }
    var name: String { (relativePath as NSString).lastPathComponent }
}

enum GroupStatus: Hashable, Sendable {
    case new
    /// Listed in the manifests of every drive already.
    case alreadyCopied
    /// Its name is taken, on a drive or by another shot of this backup. Nothing
    /// is ever overwritten, so a conflict holds the whole backup back.
    case conflict(String)
    /// None of its pictures, clips or sounds is of a kind ticked: it stays on
    /// the card with its sidecars, and takes no number.
    case unticked
}

struct PlannedGroup: Identifiable, Hashable, Sendable {
    let group: MediaGroup
    let sourceID: String
    let volumeName: String
    let day: ShootDay
    let baseName: String
    /// From the drive's root; empty when the pattern is.
    let shootFolder: String
    let files: [PlannedFile]
    /// Files of a kind left unticked, which stay on the card.
    let leftOut: [MediaFile]
    let status: GroupStatus
    /// Where a shot already saved was found, which is not always tonight's
    /// folder: a card kept from yesterday is recognised under yesterday's
    /// client, and stays there.
    var savedIn: String?

    var id: String { sourceID + "/" + group.key }
    var size: Int64 { files.reduce(0) { $0 + $1.file.size } }
}

struct IngestPlan: Sendable {
    var groups: [PlannedGroup] = []
    var shootFolders: [String] = []
    /// The name pattern it used, written into the journal so a folder can be
    /// explained months later.
    var namePattern = ""
    /// The drives this plan was made for, and the change it was made from: a
    /// plan is only ever run against the drives it counted, and never while a
    /// newer one is being made. A name typed a second before ⌘↩ would
    /// otherwise be copied under the name before it.
    var drives: [String] = []
    var generation = 0

    var toCopy: [PlannedGroup] { groups.filter { $0.status == .new } }
    var filesToCopy: Int { toCopy.reduce(0) { $0 + $1.files.count } }
    var bytesToCopy: Int64 { toCopy.reduce(0) { $0 + $1.size } }
    var alreadyCopied: Int { groups.filter { $0.status == .alreadyCopied }.count }
    var unticked: Int { groups.filter { $0.status == .unticked }.count }
    var conflicts: [PlannedGroup] {
        groups.filter { if case .conflict = $0.status { true } else { false } }
    }
    var leftOutCount: Int { groups.reduce(0) { $0 + $1.leftOut.count } }
    var days: [ShootDay] { Array(Set(toCopy.map(\.day))).sorted() }
}

/// What is already on a drive, in one shoot's folder.
struct DestinationIndex: Sendable {
    /// Base names of the pictures, clips and sounds there, by kind.
    var stems: [MediaCategory: [String]] = [:]
    /// Every file's path from the shoot's folder, lower case: APFS and exFAT
    /// are both blind to case.
    var paths: Set<String> = []
    /// Fingerprints of the files a record lists **and** that are still lying
    /// there, at their path and at their size.
    ///
    /// A record is a memory, not a proof. A file sorted out by hand, a folder
    /// moved to the archive, a drive emptied for the trip: the record still
    /// names them, and skipping on its word alone would let a card be
    /// formatted with no second copy left anywhere. So the shoot's folder is
    /// walked anyway, and only what answers is counted as saved.
    var fingerprints: Set<String> = []

    static func load(drive: URL, shootFolder: String) -> DestinationIndex {
        let folder = shootFolder.isEmpty ? drive : drive.appendingPathComponent(shootFolder)
        var index = DestinationIndex()
        guard FileManager.default.fileExists(atPath: folder.path) else { return index }
        let depth = folder.standardizedFileURL.pathComponents.count
        var sizes: [String: Int64] = [:]
        let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == History.folderName {
                walker?.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
            index.paths.insert(relative.lowercased())
            sizes[relative.lowercased()] = Int64(values?.fileSize ?? 0)
            let folders = Array(relative.split(separator: "/").dropLast().map(String.init))
            switch MediaTypes.role(forExtension: url.pathExtension, folders: folders) {
            case .raw, .jpeg, .heif: index.stems[.photo, default: []].append(url.deletingPathExtension().lastPathComponent)
            case .video: index.stems[.video, default: []].append(url.deletingPathExtension().lastPathComponent)
            case .audio: index.stems[.audio, default: []].append(url.deletingPathExtension().lastPathComponent)
            default: break
            }
        }
        for entry in History.entries(in: folder) where sizes[entry.path.lowercased()] == entry.size {
            index.fingerprints.insert(entry.fingerprint)
        }
        return index
    }
}

enum Planner {
    /// Names every shot of every card and says where each file goes.
    ///
    /// Shots are numbered in the order they were taken, all cards together, so
    /// two bodies on one shoot interleave. Numbers carry on from the highest
    /// already on the drives for the same day, client and project. A shot is
    /// left out only where every drive both lists it and still holds it, at its
    /// size: on one drive only, or listed but gone, it is copied again, because
    /// a backup that is on one drive and not the other is not a backup.
    static func plan(
        sources: [PlanSource],
        settings: IngestSettings,
        fixedDay: ShootDay?,
        drives: [URL],
        index: (URL, String) -> DestinationIndex = DestinationIndex.load,
        journal: (URL) -> DriveJournal = DriveJournal.load
    ) -> IngestPlan {
        let template = NameTemplate(settings.namePattern)
        let folderTemplate = NameTemplate(settings.folderPattern)
        let initials = Sanitize.code(settings.initials)
        let client = Sanitize.field(settings.client)
        let project = Sanitize.field(settings.project)

        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1.id, $0) })
        let items = sources.flatMap { source in source.groups.map { (source, $0) } }.sorted { a, b in
            if a.1.captureDate != b.1.captureDate { return a.1.captureDate < b.1.captureDate }
            if a.0.id != b.0.id { return order[a.0.id]! < order[b.0.id]! }
            return a.1.key < b.1.key
        }

        var journals: [String: DriveJournal] = [:]
        func journalFor(_ drive: URL) -> DriveJournal {
            if let found = journals[drive.path] { return found }
            let loaded = journal(drive)
            journals[drive.path] = loaded
            return loaded
        }
        // A backup that never wrote its closing line was cut off. What it did
        // verify is known good and is skipped whatever the setting says, or
        // "Reprendre" would copy the whole card again under new numbers.
        let skipSaved = settings.skipAlreadyCopied || drives.contains { journalFor($0).interrupted }

        var indexes: [String: DestinationIndex] = [:]
        func indexFor(_ drive: URL, _ folder: String) -> DestinationIndex {
            let key = drive.path + "\u{0}" + folder
            if let found = indexes[key] { return found }
            let loaded = index(drive, folder)
            indexes[key] = loaded
            return loaded
        }

        let timeFormat = DateFormatter()
        timeFormat.locale = Locale(identifier: "en_US_POSIX")
        timeFormat.dateFormat = "HHmmss"

        var counters: [String: Int] = [:]
        var taken: Set<String> = []
        var planned: [PlannedGroup] = []
        var folders: [String] = []

        for (source, group) in items {
            let day = fixedDay ?? ShootDay(date: group.captureDate, cutoffHour: settings.dayCutoffHour)
            var values = NameValues(
                day: day,
                time: timeFormat.string(from: group.captureDate),
                initials: initials,
                client: client,
                project: project,
                camera: Sanitize.code(source.cameraLabel),
                original: Sanitize.fileName(group.anchor.stem),
                type: group.category == .photo ? "PHOTO" : group.category == .video ? "VIDEO" : "AUDIO",
                padding: settings.padding
            )
            let shootFolder = folderTemplate.renderPath(values)

            let kept = group.files.filter { settings.includes($0.kind) }
            let leftOut = group.files.filter { !settings.includes($0.kind) }
            // The anchor among what is kept: unticking the RAW puts the XMP
            // beside the JPEG.
            guard let anchor = kept.filter(\.role.isPrimary).min(by: { $0.role.anchorRank < $1.role.anchorRank }) else {
                planned.append(PlannedGroup(
                    group: group, sourceID: source.id, volumeName: source.volumeName, day: day,
                    baseName: "", shootFolder: shootFolder, files: [], leftOut: group.files, status: .unticked
                ))
                continue
            }
            if !folders.contains(shootFolder) { folders.append(shootFolder) }

            // Tonight's folder knows a card that was not formatted; the drive's
            // journal knows it whatever it was filed under, so renaming the
            // client does not file yesterday's shots under tonight's.
            let copiedEverywhere = !drives.isEmpty && drives.allSatisfy { drive in
                let known = indexFor(drive, shootFolder).fingerprints
                let journal = journalFor(drive)
                return kept.allSatisfy { known.contains($0.fingerprint) || journal.holds($0.fingerprint, on: drive) }
            }
            if copiedEverywhere, skipSaved {
                var folder: String?
                for drive in drives {
                    if let path = journalFor(drive).saved[anchor.fingerprint]?.path {
                        folder = (path as NSString).deletingLastPathComponent
                        break
                    }
                }
                planned.append(PlannedGroup(
                    group: group, sourceID: source.id, volumeName: source.volumeName, day: day,
                    baseName: "", shootFolder: shootFolder, files: [], leftOut: leftOut, status: .alreadyCopied,
                    savedIn: folder ?? shootFolder
                ))
                continue
            }

            if template.uses(.number) {
                let category = settings.sharedCounter ? nil : group.category
                let scope = template.counterScope(values) + "\u{0}" + shootFolder + "\u{0}" + (category?.rawValue ?? "")
                if counters[scope] == nil {
                    var highest = 0
                    if let expression = template.counterExpression(values) {
                        for drive in drives {
                            let stems = indexFor(drive, shootFolder).stems
                            // The names lying there, and the names this drive
                            // has handed out before: a shot sorted out, or a
                            // folder moved to an archive, must not give its
                            // number to another shot.
                            let pool = (category.map { stems[$0] ?? [] } ?? stems.values.flatMap { $0 })
                                + journalFor(drive).names(in: shootFolder, category: category)
                            for stem in pool {
                                let range = NSRange(stem.startIndex..., in: stem)
                                guard let match = expression.firstMatch(in: stem, range: range),
                                      let digits = Range(match.range(at: 1), in: stem),
                                      let n = Int(stem[digits]) else { continue }
                                highest = max(highest, n)
                            }
                        }
                    }
                    counters[scope] = highest + 1
                }
                values.number = counters[scope]!
                counters[scope]! += 1
            }

            let baseName = template.render(values)
            let anchorStem = anchor.stem
            var files: [PlannedFile] = []
            var status = GroupStatus.new
            for file in kept {
                let folder = settings.layout.folder(for: file.role, anchor: anchor.role, values: values)
                let name = baseName + suffix(of: file, anchorStem: anchorStem) + (file.ext.isEmpty ? "" : "." + file.ext)
                let inShoot = folder.isEmpty ? name : folder + "/" + name
                let path = shootFolder.isEmpty ? inShoot : shootFolder + "/" + inShoot
                if !taken.insert(path.lowercased()).inserted {
                    status = .conflict("« \(name) » sort deux fois de ce modèle")
                } else if let drive = drives.first(where: { indexFor($0, shootFolder).paths.contains(inShoot.lowercased()) }) {
                    status = .conflict("« \(name) » existe déjà sur \(drive.lastPathComponent)")
                }
                files.append(PlannedFile(file: file, relativePath: path))
            }
            planned.append(PlannedGroup(
                group: group, sourceID: source.id, volumeName: source.volumeName, day: day,
                baseName: baseName, shootFolder: shootFolder, files: files, leftOut: leftOut, status: status
            ))
        }
        return IngestPlan(groups: planned, shootFolders: folders)
    }

    /// What a companion keeps of its own name after its anchor's: Sony's
    /// C0001M01.XML beside C0001.MP4 keeps `M01`, so the renamed pair still
    /// follows the convention Sony's software looks for. GoPro's GL010001.LRV
    /// beside GX010001.MP4 keeps nothing.
    static func suffix(of file: MediaFile, anchorStem: String) -> String {
        guard !file.role.isPrimary else { return "" }
        let stem = file.stem
        guard stem.count > anchorStem.count, stem.uppercased().hasPrefix(anchorStem.uppercased()) else { return "" }
        return String(stem.dropFirst(anchorStem.count))
    }
}
