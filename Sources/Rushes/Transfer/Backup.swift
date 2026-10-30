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
    /// Sweeping partials, writing the records, syncing the drives: no byte
    /// of a card moves, and that is not a stall.
    var quiet = false

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
    /// When the records were written: the manifests and the report share it.
    var recorded = Date()
    /// The shoot folders written, on the first drive, for "Afficher dans le Finder".
    var folders: [URL] = []
    /// Drives that would not confirm that what they were given is written
    /// down. Nothing copied tonight can be counted on there yet.
    var unflushed: [String] = []
    /// What was verified, by shoot folder: the manifests' entries, kept for
    /// the report written once the cards have their verdicts.
    var entries: [String: [Manifest.Entry]] = [:]
    /// The same, by drive path then shoot folder: what each drive holds of
    /// tonight, which is not all of it when drives receive different kinds.
    var onDrives: [String: [String: [Manifest.Entry]]] = [:]
    /// Bytes read from the cards plus every copy written and read back.
    var bytesMoved: Int64 = 0

    var succeeded: Bool { failures.isEmpty && !cancelled && stopped == nil && unflushed.isEmpty }
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
        state.total = plan.bytesMoved
        state.quiet = true
        progress(state)

        sweepPartials(plan, drives: drives)
        state.quiet = false

        // Every drive is told a backup has begun. Cut off before the closing
        // line, the journal says so by itself, and the next run trusts what it
        // verified rather than copying the card again.
        let id = UUID().uuidString
        var start = JournalLine(kind: .start, backup: id, at: Date(), version: Bundle.main.version, pattern: plan.namePattern)
        start.client = plan.client
        start.project = plan.project
        start.initials = plan.initials
        start.days = plan.days
        for drive in drives {
            do {
                try Journal.append([start], on: drive)
            } catch {
                report.failures.append(.init(file: Journal.fileName, message: error.localizedDescription))
            }
        }

        var entries: [String: [Manifest.Entry]] = [:]
        var onDrives: [String: [String: [Manifest.Entry]]] = [:]
        let tally = Tally(state, progress: progress)
        let buffers = Copier.Buffers()
        let verifier = DispatchQueue(label: "eu.stevenrsl.rushes.verify", qos: .userInitiated)
        // Files settled without a failure, by group: a group counts as copied
        // once all of its files are.
        var settledOK = Array(repeating: 0, count: groups.count)

        /// What one file's end means for the report. Returns false when the
        /// backup must stop.
        func settle(_ job: Job, _ outcome: Result<String, Error>) -> Bool {
            let planned = job.planned, group = job.group
            switch outcome {
            case .success(let hash):
                report.filesCopied += 1
                report.bytesCopied += planned.file.size
                report.bytesMoved += job.expected
                settledOK[job.index] += 1
                let inShoot = group.shootFolder.isEmpty
                    ? planned.relativePath
                    : String(planned.relativePath.dropFirst(group.shootFolder.count + 1))
                let entry = Manifest.Entry(
                    original: planned.file.relativePath,
                    volume: group.volumeName,
                    path: inShoot,
                    size: planned.file.size,
                    xxh64: hash,
                    fingerprint: planned.file.fingerprint,
                    captured: group.group.captureDate
                )
                entries[group.shootFolder, default: []].append(entry)
                for drive in job.mine { onDrives[drive.path, default: [:]][group.shootFolder, default: []].append(entry) }
                report.failures += job.journalFailures
            case .failure(is CancellationError):
                report.cancelled = true
                return false
            case .failure(let error):
                // What this file had counted goes; what it should have counted
                // is added back so the bar still ends at the end.
                tally.makeUp(job)
                report.failures.append(.init(file: planned.file.relativePath, message: error.localizedDescription, source: group.sourceID))
                if (error as? Copier.Failure)?.fatal == true {
                    report.stopped = error.localizedDescription
                    tally.fileDone()
                    return false
                }
            }
            tally.fileDone()
            return true
        }

        var inFlight: (job: Job, done: DispatchGroup)?
        /// Waits for the file being read back and settles it.
        func land() -> Bool {
            guard let (job, done) = inFlight else { return true }
            inFlight = nil
            done.wait()
            return settle(job, job.outcome!)
        }

        outer: for (index, group) in groups.enumerated() {
            // The drives this shot goes to: all of them, or those that receive
            // its kind. A copy is named on each of these or on none.
            let mine = drives.filter { group.drives.contains($0.path) }
            for planned in group.files {
                if isCancelled() {
                    report.cancelled = true
                    break outer
                }
                let job = Job(planned: planned, group: group, index: index, mine: mine)
                tally.begin(planned.name)
                let targets = mine.map { $0.appendingPathComponent(planned.relativePath) }
                let written = Result {
                    try Copier.write(
                        planned.file.url,
                        to: targets,
                        size: planned.file.size,
                        modified: planned.file.modified,
                        created: planned.file.created,
                        buffers: buffers,
                        isCancelled: isCancelled
                    ) { tally.add($0, for: job, verifying: false) }
                }
                tally.written()

                // The file before this one, read back while this one was read
                // from the card.
                let carryOn = land()
                switch written {
                case .success(let written):
                    guard carryOn else {
                        Copier.discard(written)
                        break outer
                    }
                    let done = DispatchGroup()
                    inFlight = (job, done)
                    verifier.async(group: done) {
                        job.outcome = Result {
                            try Copier.verify(written, buffers: buffers, isCancelled: isCancelled) {
                                tally.add($0, for: job, verifying: true)
                            }
                        }
                        guard case .success(let hash) = job.outcome else { return }
                        // Written now, not at the end: this line is what a
                        // backup that never ends leaves behind.
                        let line = JournalLine(
                            kind: .file, backup: id, at: Date(),
                            path: planned.relativePath, shoot: group.shootFolder,
                            fingerprint: planned.file.fingerprint, xxh64: hash, size: planned.file.size,
                            original: planned.file.relativePath, volume: group.volumeName,
                            category: group.group.category.rawValue
                        )
                        for drive in mine {
                            do {
                                try Journal.append([line], on: drive)
                            } catch {
                                job.journalFailures.append(.init(file: Journal.fileName, message: error.localizedDescription))
                            }
                        }
                    }
                case .failure(let error):
                    guard carryOn, settle(job, .failure(error)) else { break outer }
                }
            }
        }
        // The last file, or the one still being read back when the backup
        // stopped: what it verified counts.
        _ = land()
        report.groupsCopied = zip(groups, settledOK).filter { $1 == $0.files.count }.count
        state = tally.state

        // Whatever happened, what was copied and checked is written down, so
        // the next attempt skips it.
        state.quiet = true
        state.current = ""
        progress(state)
        let now = Date()
        report.recorded = now
        // Each drive's records list what that drive holds, and nothing it
        // does not: the audit reads them back against the drive.
        for drive in drives {
            for (folder, list) in onDrives[drive.path] ?? [:] {
                let shoot = folder.isEmpty ? drive : drive.appendingPathComponent(folder)
                do {
                    try History.write(list, in: shoot, at: now)
                } catch {
                    report.failures.append(.init(file: History.folderName, message: "Le relevé n'a pas pu être écrit sur \(drive.lastPathComponent) : \(error.localizedDescription)"))
                }
                if plan.writesMHL {
                    do {
                        try ASCMHL.write(list, in: shoot, at: now, version: Bundle.main.version)
                    } catch {
                        report.failures.append(.init(file: ASCMHL.folderName, message: "L'ASC MHL n'a pas pu être écrit sur \(drive.lastPathComponent) : \(error.localizedDescription)"))
                    }
                }
            }
        }
        // The closing line comes last and says whether anything was left
        // undone. Until a complete one is written, this drive counts as having
        // a backup to resume, and the next plan skips what was verified
        // whatever the setting says. That is what "Reprendre" used to keep in
        // memory, and lost when the app quit. A crash writes no line at all,
        // which reads the same.
        //
        // Before that, and before anyone is told a card can be formatted, the
        // drives are synced whole. Even with nothing copied tonight: a
        // "Reprendre" after a crash may find a card's every shot already there,
        // named by a run that never reached this line.
        if !groups.isEmpty {
            for drive in drives where !Journal.flushDevice(on: drive) {
                report.unflushed.append(drive.lastPathComponent)
            }
        }
        let complete = report.failures.isEmpty && !report.cancelled && report.stopped == nil && report.unflushed.isEmpty
        let end = JournalLine(kind: .end, backup: id, at: now, complete: complete)
        for drive in drives { try? Journal.append([end], on: drive) }

        report.entries = entries
        report.onDrives = onDrives
        // One folder per shoot, on the first drive that received some of it.
        for folder in plan.shootFolders {
            guard let drive = drives.first(where: { onDrives[$0.path]?[folder] != nil }) ?? drives.first else { continue }
            report.folders.append(folder.isEmpty ? drive : drive.appendingPathComponent(folder))
        }
        report.finished = Date()
        progress(state)
        return report
    }

    /// One file on its way: written by this loop, then read back, named
    /// and journaled on `verifier` while the card is read for the next.
    private final class Job: @unchecked Sendable {
        let planned: PlannedFile
        let group: PlannedGroup
        let index: Int
        let mine: [URL]
        /// Bytes this file has added to the bar, so a failure can make up
        /// the difference.
        var counted: Int64 = 0
        var outcome: Result<String, Error>?
        var journalFailures: [BackupReport.Failure] = []
        init(planned: PlannedFile, group: PlannedGroup, index: Int, mine: [URL]) {
            self.planned = planned
            self.group = group
            self.index = index
            self.mine = mine
        }
        var expected: Int64 { planned.file.size * Int64(1 + mine.count) }
    }

    /// The bar, fed by the card's reads on one thread and the drives' on
    /// another, and handed on at most ten times a second.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: BackupProgress
        private var writing = false
        private var lastReport = Date.distantPast
        private let progress: @Sendable (BackupProgress) -> Void

        init(_ state: BackupProgress, progress: @escaping @Sendable (BackupProgress) -> Void) {
            stored = state
            self.progress = progress
        }

        var state: BackupProgress { lock.withLock { stored } }

        func begin(_ name: String) {
            update(force: true) {
                $0.current = name
                $0.verifying = false
                writing = true
            }
        }

        func written() { lock.withLock { writing = false } }

        /// "Vérification des copies" only while the card is not being read:
        /// the card is what the night waits for.
        func add(_ bytes: Int64, for job: Job, verifying: Bool) {
            update {
                $0.done += bytes
                if !verifying { $0.read += bytes }
                $0.verifying = verifying && !writing
                job.counted += bytes
            }
        }

        func makeUp(_ job: Job) {
            update { $0.done += job.expected - job.counted }
        }

        func fileDone() { update(force: true) { $0.filesDone += 1 } }

        private func update(force: Bool = false, _ change: (inout BackupProgress) -> Void) {
            let snapshot: BackupProgress? = lock.withLock {
                change(&stored)
                let now = Date()
                guard force || now.timeIntervalSince(lastReport) > 0.1 else { return nil }
                lastReport = now
                return stored
            }
            if let snapshot { progress(snapshot) }
        }
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
