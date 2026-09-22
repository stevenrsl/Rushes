import Foundation

/// Runs a plan: every file to every drive, checked, then the manifests.
struct BackupProgress: Sendable {
    /// Bytes read from the cards plus bytes read back from the drives.
    var done: Int64 = 0
    var total: Int64 = 0
    /// Bytes read from the cards only, for the speed.
    var read: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var current = ""
    var verifying = false

    var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
}

struct BackupReport: Sendable {
    struct Failure: Sendable, Hashable {
        let file: String
        let message: String
        /// The card it came from, so a card can be told whether anything of
        /// its own was left behind. Empty for a failure of the whole backup.
        var source = ""
    }

    var filesCopied = 0
    var bytesCopied: Int64 = 0
    var groupsCopied = 0
    var failures: [Failure] = []
    var cancelled = false
    /// What stopped everything: a full disk, a drive or a card pulled out.
    var stopped: String?
    var started = Date()
    var finished = Date()
    /// The shoot folders written, on the first drive, for "Afficher dans le Finder".
    var folders: [URL] = []

    var succeeded: Bool { failures.isEmpty && !cancelled && stopped == nil }
}

enum Backup {
    static func run(
        _ plan: IngestPlan,
        drives: [URL],
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) -> BackupReport {
        var report = BackupReport()
        let groups = plan.toCopy
        var state = BackupProgress()
        state.filesTotal = groups.reduce(0) { $0 + $1.files.count }
        state.total = plan.bytesToCopy * Int64(1 + drives.count)
        progress(state)

        sweepPartials(plan, drives: drives)

        // Every drive is told a backup has begun. Cut off before the closing
        // line, the journal says so by itself, and the next run trusts what it
        // verified rather than copying the card again.
        let id = UUID().uuidString
        let start = JournalLine(kind: .start, backup: id, at: Date(), version: Bundle.main.version, pattern: plan.namePattern)
        for drive in drives {
            do {
                try Journal.append([start], on: drive)
            } catch {
                report.failures.append(.init(file: Journal.fileName, message: error.localizedDescription))
            }
        }

        var entries: [String: [Manifest.Entry]] = [:]
        var lastReport = Date.distantPast

        func publish(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                progress(state)
            }
        }

        outer: for group in groups {
            var groupOK = true
            for planned in group.files {
                if isCancelled() {
                    report.cancelled = true
                    break outer
                }
                state.current = planned.name
                state.verifying = false
                publish(force: true)
                let targets = drives.map { $0.appendingPathComponent(planned.relativePath) }
                let before = state.done
                do {
                    let hash = try Copier.copy(
                        planned.file.url,
                        to: targets,
                        modified: planned.file.modified,
                        created: planned.file.created,
                        isCancelled: isCancelled
                    ) { bytes, verifying in
                        state.done += bytes
                        if !verifying { state.read += bytes }
                        state.verifying = verifying
                        publish()
                    }
                    report.filesCopied += 1
                    report.bytesCopied += planned.file.size
                    let inShoot = group.shootFolder.isEmpty
                        ? planned.relativePath
                        : String(planned.relativePath.dropFirst(group.shootFolder.count + 1))
                    entries[group.shootFolder, default: []].append(Manifest.Entry(
                        original: planned.file.relativePath,
                        volume: group.volumeName,
                        path: inShoot,
                        size: planned.file.size,
                        xxh64: hash,
                        fingerprint: planned.file.fingerprint,
                        captured: group.group.captureDate
                    ))
                    // Written now, not at the end: this line is what a backup
                    // that never ends leaves behind.
                    let line = JournalLine(
                        kind: .file, backup: id, at: Date(),
                        path: planned.relativePath, shoot: group.shootFolder,
                        fingerprint: planned.file.fingerprint, xxh64: hash, size: planned.file.size,
                        original: planned.file.relativePath, volume: group.volumeName,
                        category: group.group.category.rawValue
                    )
                    for drive in drives {
                        do {
                            try Journal.append([line], on: drive)
                        } catch {
                            report.failures.append(.init(file: Journal.fileName, message: error.localizedDescription))
                        }
                    }
                } catch is CancellationError {
                    report.cancelled = true
                    break outer
                } catch {
                    groupOK = false
                    // What this file had counted goes; what it should have counted
                    // is added back so the bar still ends at the end.
                    state.done = before + planned.file.size * Int64(1 + drives.count)
                    let failure = error as? Copier.Failure
                    report.failures.append(.init(file: planned.file.relativePath, message: error.localizedDescription, source: group.sourceID))
                    if failure?.fatal == true {
                        report.stopped = error.localizedDescription
                        break outer
                    }
                }
                state.filesDone += 1
                publish(force: true)
            }
            if groupOK { report.groupsCopied += 1 }
        }

        // Whatever happened, what was copied and checked is written down, so
        // the next attempt skips it.
        let now = Date()
        for drive in drives {
            for (folder, list) in entries {
                let shoot = folder.isEmpty ? drive : drive.appendingPathComponent(folder)
                do {
                    try History.write(list, in: shoot, at: now)
                } catch {
                    report.failures.append(.init(file: History.folderName, message: "Le relevé n'a pas pu être écrit sur \(drive.lastPathComponent) : \(error.localizedDescription)"))
                }
            }
        }
        // The closing line comes last, and only if nothing was left undone:
        // until it is there, this backup counts as unfinished, and the next
        // plan skips what it verified whatever the setting says. That is what
        // "Reprendre" used to keep in memory, and lost when the app quit.
        if report.succeeded {
            let end = JournalLine(kind: .end, backup: id, at: now)
            for drive in drives { try? Journal.append([end], on: drive) }
        }
        // Before anyone is told a card can be formatted, the drives are asked
        // to put what they are holding onto the platters. fsync alone leaves
        // it in the drive's own cache, which a pulled cable empties.
        for drive in drives { Journal.flushDevice(on: drive) }

        if let drive = drives.first {
            report.folders = plan.shootFolders.map { $0.isEmpty ? drive : drive.appendingPathComponent($0) }
        }
        report.finished = Date()
        publish(force: true)
        return report
    }

    /// Copies in progress left by a backup that was cut off. They never look
    /// like finished files, but they hold on to room the drive needs tonight,
    /// and nothing else would ever come back for them.
    private static func sweepPartials(_ plan: IngestPlan, drives: [URL]) {
        for drive in drives {
            for folder in plan.shootFolders {
                let shoot = folder.isEmpty ? drive : drive.appendingPathComponent(folder)
                let walker = FileManager.default.enumerator(at: shoot, includingPropertiesForKeys: nil)
                while let url = walker?.nextObject() as? URL {
                    let name = url.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".rushes-partial") { unlink(url.path) }
                }
            }
        }
    }
}
