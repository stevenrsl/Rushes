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
                } catch is CancellationError {
                    report.cancelled = true
                    break outer
                } catch {
                    groupOK = false
                    // What this file had counted goes; what it should have counted
                    // is added back so the bar still ends at the end.
                    state.done = before + planned.file.size * Int64(1 + drives.count)
                    let failure = error as? Copier.Failure
                    report.failures.append(.init(file: planned.file.relativePath, message: error.localizedDescription))
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
        if let drive = drives.first {
            report.folders = plan.shootFolders.map { $0.isEmpty ? drive : drive.appendingPathComponent($0) }
        }
        report.finished = Date()
        publish(force: true)
        return report
    }
}
