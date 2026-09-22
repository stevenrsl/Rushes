import Darwin
import Foundation

/// The running record of a drive: `_RUSHES/journal.jsonl` at its root, one
/// line per file, written and flushed the moment that file is verified.
///
/// The manifests in each shoot's folder say what one night put there, and they
/// travel with the folder when it is archived. They are written when the
/// backup ends, which is too late for the three things this file answers:
///
/// - **What survived a backup that never ended.** A crash, a cable, a lid
///   closed: the journal already holds every file verified until then, so the
///   next run copies only the rest instead of the whole card again.
/// - **Where a shot went, whatever it was called.** The manifests are found
///   through the shoot folder, which is built from tonight's client, project
///   and day. Rename the client and a card kept from yesterday is copied again
///   into the new client's folder. The journal is read from the drive's root,
///   so a shot is recognised by its fingerprint alone.
/// - **Which numbers are already spoken for.** The counter carries on after the
///   highest number lying in the folder. Sort out a few rejects, or empty the
///   drive after moving the shoot to an archive, and those numbers would be
///   handed out a second time, to other shots.
///
/// It is a derived file: every line it holds is also in a manifest. Deleted,
/// it costs the three answers above until the next backup, never a file.
struct JournalLine: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case start, file, end
    }

    var kind: Kind
    /// The backup this line belongs to. A `start` with no `end` was cut off.
    var backup: String
    var at: Date
    /// From the drive's root, on `file` lines.
    var path: String?
    /// The shoot folder it went into, which the path alone cannot tell apart
    /// from the folders inside it.
    var shoot: String?
    var fingerprint: String?
    var xxh64: String?
    var size: Int64?
    /// The name the camera gave it, and the card it came from.
    var original: String?
    var volume: String?
    /// photo, video or sound: photos and videos can count apart.
    var category: String?
    /// On `start` lines, so a folder can still be explained months later.
    var version: String?
    var pattern: String?
}

enum Journal {
    static let fileName = "journal.jsonl"

    static func url(on drive: URL) -> URL {
        drive.appendingPathComponent(History.folderName).appendingPathComponent(fileName)
    }

    /// Appends lines and flushes them, so a backup cut off a second later
    /// still finds them. Nothing here ever rewrites what is above.
    static func append(_ lines: [JournalLine], on drive: URL) throws {
        guard !lines.isEmpty else { return }
        let url = self.url(on: drive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = Data()
        for line in lines {
            text.append(try encoder.encode(line))
            text.append(0x0A)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw JournalError(path: url.path) }
        defer { close(fd) }
        try text.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(fd, buffer.baseAddress! + written, buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw JournalError(path: url.path)
                }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw JournalError(path: url.path) }
    }

    /// Asks the drive to write what it still holds in its own cache all the
    /// way down. `fsync` only hands the bytes to the drive; `F_FULLFSYNC` is
    /// what makes them survive the cable coming out a second later.
    static func flushDevice(on drive: URL) {
        let fd = open(url(on: drive).path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    /// Every line the drive holds. A line that will not decode is skipped: the
    /// tail of a journal cut off mid-write must not cost the rest of it.
    static func read(on drive: URL) -> [JournalLine] {
        guard let data = try? Data(contentsOf: url(on: drive)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var lines: [JournalLine] = []
        for raw in data.split(separator: 0x0A) where !raw.isEmpty {
            if let line = try? decoder.decode(JournalLine.self, from: Data(raw)) { lines.append(line) }
        }
        return lines
    }
}

extension Bundle {
    /// What wrote a line, so a folder made by an older Rushes can be told
    /// apart from one made today. "0" under `swift test`, which has no bundle.
    var version: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}

struct JournalError: LocalizedError {
    let path: String
    var errorDescription: String? {
        "Le journal n'a pas pu être écrit (\(String(cString: strerror(errno)))) : \((path as NSString).lastPathComponent)"
    }
}

/// What one drive has kept, across every shoot it holds, as its journal tells
/// it. Whether a file is still there is asked of the drive itself, never of
/// the journal: a record is a memory, not a proof.
struct DriveJournal: Sendable {
    struct Saved: Sendable {
        /// From the drive's root.
        var path: String
        var size: Int64
    }

    /// By fingerprint, the last place that file was put.
    var saved: [String: Saved] = [:]
    /// The base names already handed out, by shoot folder, whether or not the
    /// files are still lying there.
    var namesGiven: [String: [Name]] = [:]

    struct Name: Sendable {
        var stem: String
        var category: String?
    }
    /// A backup was started here and never ended: what it did verify is known
    /// good, and is skipped even when the setting copies saved shots again.
    var interrupted = false

    /// A plan is made again at every keystroke, and a year of shooting is a
    /// long file: it is read once per state of it, then kept. The journal's
    /// own size and date say when that state has changed.
    static func load(_ drive: URL) -> DriveJournal {
        let url = Journal.url(on: drive)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(values?.fileSize ?? -1)/\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return JournalCache.shared.journal(for: drive.path, stamp: stamp) { read(drive) }
    }

    private static func read(_ drive: URL) -> DriveJournal {
        var journal = DriveJournal()
        var open: Set<String> = []
        for line in Journal.read(on: drive) {
            switch line.kind {
            case .start:
                open.insert(line.backup)
            case .end:
                open.remove(line.backup)
            case .file:
                guard let path = line.path, let fingerprint = line.fingerprint else { continue }
                journal.saved[fingerprint] = Saved(path: path, size: line.size ?? 0)
                let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                journal.namesGiven[line.shoot ?? "", default: []].append(Name(stem: stem, category: line.category))
            }
        }
        journal.interrupted = !open.isEmpty
        return journal
    }

    /// Whether the drive still holds that file, where it was put and at the
    /// size it had. Sorted out by hand, moved to an archive, or on a drive
    /// emptied for the trip, and the answer is no: it is copied again.
    func holds(_ fingerprint: String, on drive: URL) -> Bool {
        guard let saved = saved[fingerprint] else { return false }
        var status = stat()
        guard stat(drive.appendingPathComponent(saved.path).path, &status) == 0 else { return false }
        return status.st_size == saved.size
    }

    /// The names this drive has already handed out under a shoot folder, so a
    /// number is never given twice even when the files have since moved on.
    /// Photos and videos are asked for apart when they count apart.
    func names(in shootFolder: String, category: MediaCategory?) -> [String] {
        let all = namesGiven[shootFolder] ?? []
        guard let category else { return all.map(\.stem) }
        return all.filter { $0.category == nil || $0.category == category.rawValue }.map(\.stem)
    }
}

/// One journal per drive, kept for as long as that drive's journal file does
/// not change. Read from the planning thread, which is not the main one.
private final class JournalCache: @unchecked Sendable {
    static let shared = JournalCache()
    private let lock = NSLock()
    private var kept: [String: (stamp: String, journal: DriveJournal)] = [:]

    func journal(for path: String, stamp: String, build: () -> DriveJournal) -> DriveJournal {
        lock.lock()
        if let found = kept[path], found.stamp == stamp {
            lock.unlock()
            return found.journal
        }
        lock.unlock()
        let journal = build()
        lock.withLock { kept[path] = (stamp, journal) }
        return journal
    }
}
