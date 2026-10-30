import Foundation
import Testing
@testable import Rushes

// A card on disk, two drives on disk, the real scanner, planner and copier.

final class Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ path: String, in base: URL, size: Int, date: Date) throws -> Data {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        return data
    }
}

@Suite("Backup", .serialized)
struct BackupTests {
    @Test("a Sony card to two drives, checked, recorded, and recognised the next night")
    func endToEnd() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let driveA = try box.folder("SSD-A")
        let driveB = try box.folder("SSD-B")
        let t = local(2026, 9, 21, 23, 30)

        let arw = try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 9_000_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00001.JPG", in: card, size: 300_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00002.JPG", in: card, size: 1, date: t.addingTimeInterval(60))
        try box.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", in: card, size: 17_000_123, date: t.addingTimeInterval(3600 * 2))
        try box.write("PRIVATE/M4ROOT/CLIP/C0001M01.XML", in: card, size: 2_000, date: t.addingTimeInterval(3600 * 2))
        try box.write("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", in: card, size: 5_000, date: t.addingTimeInterval(3600 * 2))
        try box.write("PRIVATE/M4ROOT/MEDIAPRO.XML", in: card, size: 800, date: t)
        try box.write("PRIVATE/SONY/SONYCARD.IND", in: card, size: 10, date: t)
        try box.write(".Spotlight-V100/store.db", in: card, size: 10, date: t)

        #expect(CardScanner.looksLikeCard(card))
        let scan = try CardScanner.scan(card)
        #expect(scan.brand == .sony)
        #expect(scan.photoCount == 2)
        #expect(scan.videoCount == 1)
        #expect(scan.orphans.map(\.name) == ["MEDIAPRO.XML"])
        #expect(scan.unknownCount == 1)

        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        settings.sharedCounter = true
        settings.skipAlreadyCopied = true
        settings.kindChoices = [FileKind(role: .sidecar, ext: "XML").id: true]
        let sources = [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)]
        let drives = [driveA, driveB]
        let plan = Planner.plan(sources: sources, settings: settings, fixedDay: nil, drives: drives)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.filesToCopy == 5)

        let seen = Counter()
        let report = Backup.run(plan, drives: drives, isCancelled: { false }) { _ in seen.bump() }
        #expect(report.succeeded, "\(report.failures)")
        #expect(report.filesCopied == 5)
        #expect(seen.value > 0)

        for drive in drives {
            let shoot = drive.appendingPathComponent("260921_Kaffi_Lexus")
            let raw = shoot.appendingPathComponent("PHOTO/RAW/260921_SR_Kaffi_Lexus_0001.ARW")
            #expect(try Data(contentsOf: raw) == arw)
            #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("PHOTO/JPG/260921_SR_Kaffi_Lexus_0001.JPG").path))
            #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("PHOTO/JPG/260921_SR_Kaffi_Lexus_0002.JPG").path))
            // Shot at 01:30 on the 22nd: still the 21st's shoot.
            #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("VIDEO/260921_SR_Kaffi_Lexus_0003.MP4").path))
            #expect(FileManager.default.fileExists(atPath: shoot.appendingPathComponent("VIDEO/260921_SR_Kaffi_Lexus_0003M01.XML").path))
            let rawDate = try FileManager.default.attributesOfItem(atPath: raw.path)[.modificationDate] as? Date
            #expect(rawDate == t)

            let everything = FileManager.default.enumerator(atPath: shoot.path)?.allObjects as? [String] ?? []
            #expect(!everything.contains { $0.contains("rushes-partial") })
            let records = try FileManager.default.contentsOfDirectory(atPath: shoot.appendingPathComponent("_RUSHES").path)
            #expect(records.filter { $0.hasSuffix(".json") }.count == 1)
            #expect(records.filter { $0.hasSuffix(".csv") }.count == 1)
        }

        // The card was not formatted; one more photo was taken.
        try box.write("DCIM/100MSDCF/DSC00003.JPG", in: card, size: 4_000, date: t.addingTimeInterval(3600 * 3))
        let again = try CardScanner.scan(card)
        let next = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: again.groups)],
            settings: settings, fixedDay: nil, drives: drives
        )
        #expect(next.alreadyCopied == 3)
        #expect(next.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus_0004"])

        // A record is a memory, not a proof. One shot deleted from a drive is
        // copied again even though every manifest still lists it, and another
        // one truncated is not taken for the file it names.
        try FileManager.default.removeItem(at: driveB.appendingPathComponent("260921_Kaffi_Lexus/PHOTO/JPG/260921_SR_Kaffi_Lexus_0002.JPG"))
        try Data("not the clip".utf8).write(to: driveA.appendingPathComponent("260921_Kaffi_Lexus/VIDEO/260921_SR_Kaffi_Lexus_0003.MP4"))
        let third = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: again.groups)],
            settings: settings, fixedDay: nil, drives: drives
        )
        #expect(third.alreadyCopied == 1)
        #expect(third.toCopy.count == 3)
    }

    @Test("nothing is ever replaced, and a refused copy leaves nothing behind")
    func neverOverwrites() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 20, 0)
        try box.write("DCIM/100CANON/IMG_0001.JPG", in: card, size: 1000, date: t)
        let precious = try box.write("taken.JPG", in: drive, size: 50, date: t)

        #expect(throws: Copier.Failure.self) {
            _ = try Copier.copy(
                card.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG"),
                to: [drive.appendingPathComponent("taken.JPG")],
                modified: t, created: t, isCancelled: { false }, advance: { _, _ in }
            )
        }
        #expect(try Data(contentsOf: drive.appendingPathComponent("taken.JPG")) == precious)
        #expect(try FileManager.default.contentsOfDirectory(atPath: drive.path) == ["taken.JPG"])
    }

    @Test("a cancelled copy leaves no partial file")
    func cancelled() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 20, 0)
        try box.write("DCIM/100CANON/MVI_0001.MP4", in: card, size: 30_000_000, date: t)
        let target = drive.appendingPathComponent("VIDEO/clip.MP4")
        let chunks = Counter()
        #expect(throws: CancellationError.self) {
            _ = try Copier.copy(
                card.appendingPathComponent("DCIM/100CANON/MVI_0001.MP4"),
                to: [target],
                modified: t, created: t,
                isCancelled: { chunks.value >= 1 },
                advance: { _, _ in chunks.bump() }
            )
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(left.isEmpty)
    }

    /// The card reads file N+1 while file N is read back: whatever stops
    /// the backup, nothing finished may lie outside the journal, and nothing
    /// half-done may be left at all.
    private func photoCard(_ box: Sandbox, shots: Int) throws -> (URL, IngestPlan, [URL]) {
        let card = try box.folder("CARD")
        let drives = [try box.folder("SSD-A"), try box.folder("SSD-B")]
        let t = local(2026, 9, 21, 22, 0)
        for n in 1...shots {
            try box.write(String(format: "DCIM/100MSDCF/DSC%05d.ARW", n), in: card, size: 3_000_000 + n, date: t.addingTimeInterval(Double(n)))
        }
        var settings = IngestSettings()
        settings.client = "Kaffi"
        settings.project = "Lexus"
        let scan = try CardScanner.scan(card)
        let sources = [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)]
        return (card, Planner.plan(sources: sources, settings: settings, fixedDay: nil, drives: drives), drives)
    }

    /// Every file on a drive, from its root, outside the records.
    private func files(on drive: URL) -> [String] {
        let root = drive.resolvingSymlinksInPath()
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var found: [String] = []
        while let url = walker?.nextObject() as? URL {
            let path = url.resolvingSymlinksInPath().path
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  !path.contains("/_RUSHES/") else { continue }
            found.append(String(path.dropFirst(root.path.count + 1)))
        }
        return found.sorted()
    }

    @Test("a backup cancelled with a file still being read back leaves every finished file journaled")
    func cancelledInFlight() throws {
        let box = try Sandbox()
        let (_, plan, drives) = try photoCard(box, shots: 8)
        let done = Locked(0)
        let report = Backup.run(plan, drives: drives, isCancelled: { done.read { $0 >= 3 } }) { state in
            done.write { $0 = state.filesDone }
        }
        #expect(report.cancelled)
        #expect(report.filesCopied < 8)
        for drive in drives {
            let journaled = Journal.read(on: drive).filter { $0.kind == .file }.compactMap(\.path).sorted()
            #expect(files(on: drive) == journaled, "a finished file outside the journal, or a partial left")
            #expect(journaled.count == report.filesCopied)
        }
    }

    @Test("a file the card will not give up costs that file only, before and after it are saved")
    func unreadableInFlight() throws {
        let box = try Sandbox()
        let (card, plan, drives) = try photoCard(box, shots: 6)
        let locked = card.appendingPathComponent("DCIM/100MSDCF/DSC00003.ARW")
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o644) }
        let report = Backup.run(plan, drives: drives, isCancelled: { false }) { _ in }
        #expect(report.stopped == nil)
        #expect(report.filesCopied == 5)
        #expect(report.failures.map(\.file) == ["DCIM/100MSDCF/DSC00003.ARW"])
        #expect(report.groupsCopied == 5)
        for drive in drives {
            let journaled = Journal.read(on: drive).filter { $0.kind == .file }.compactMap(\.path).sorted()
            #expect(files(on: drive) == journaled)
            #expect(journaled.count == 5)
        }
    }

    @Test("the manifest's hash is the file's")
    func hashMatches() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let data = try box.write("a.MP4", in: card, size: 12_345_678, date: .now)
        let hash = try Copier.copy(card.appendingPathComponent("a.MP4"), to: [drive.appendingPathComponent("b.MP4")],
                                   modified: .now, created: .now, isCancelled: { false }, advance: { _, _ in })
        #expect(hash == Copier.hex(XXHash64.hash(data)))
        #expect(try Copier.hash(of: drive.appendingPathComponent("b.MP4")) == hash)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

/// An exFAT volume in memory, a device of its own: a card and two drives made
/// this way do not share one SSD, as on a real night they do not.
final class RAMVolume {
    let mountPoint: URL
    private let device: String

    init?(megabytes: Int) {
        guard let device = RAMVolume.output("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\(megabytes * 2048)"]),
              device.hasPrefix("/dev/") else { return nil }
        self.device = device
        mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-ram-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard RAMVolume.output("/sbin/newfs_exfat", ["-v", "RUSHESRAM", device]) != nil,
              RAMVolume.output("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountPoint.path, device]) != nil
        else {
            _ = RAMVolume.output("/usr/bin/hdiutil", ["detach", "-force", device])
            return nil
        }
    }

    deinit {
        _ = RAMVolume.output("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
        _ = RAMVolume.output("/usr/bin/hdiutil", ["detach", "-force", device])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    private static func output(_ tool: String, _ arguments: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// RUSHES_BENCH=1 swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/rushes-release --filter bench
@Suite("Bench", .serialized, .enabled(if: ProcessInfo.processInfo.environment["RUSHES_BENCH"] != nil))
struct Bench {
    @Test("copy and check 2 GB to two folders")
    func bench() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let a = try box.folder("A"), b = try box.folder("B")
        let source = card.appendingPathComponent("big.MP4")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        var generator = SystemRandomNumberGenerator()
        var block = [UInt64](repeating: 0, count: 1 << 20)
        for i in block.indices { block[i] = generator.next() }
        let chunk = block.withUnsafeBytes { Data($0) }
        for _ in 0..<256 { handle.write(chunk) }
        try handle.close()

        var hashOnly = XXHash64()
        let start0 = Date()
        for _ in 0..<256 { hashOnly.update(chunk) }
        let hashSpeed = 2048 / Date().timeIntervalSince(start0)

        let start = Date()
        _ = try Copier.copy(source, to: [a.appendingPathComponent("x.MP4"), b.appendingPathComponent("x.MP4")],
                            modified: .now, created: .now, isCancelled: { false }, advance: { _, _ in })
        let seconds = Date().timeIntervalSince(start)
        print("BENCH hash \(Int(hashSpeed)) MB/s; copy+check 2 GB to 2 folders in \(String(format: "%.1f", seconds)) s")
    }

    /// The card on a disk image, attached again so it is read cold. The
    /// drives on images too (exFAT, as they are sold), or as plain folders,
    /// where the disk-image layer does not set the pace.
    @Test("a photo card of 300 files to two drives, whole backup", arguments: [true, false])
    func photoCard(exFAT: Bool) throws {
        guard let volume = TestVolume("ExFAT", megabytes: 2600) else { return }
        let box = try Sandbox()
        let images = exFAT ? [TestVolume("ExFAT", megabytes: 2600), TestVolume("ExFAT", megabytes: 2600)].compactMap { $0 } : []
        let drives = exFAT ? images.map(\.mountPoint) : [try box.folder("A"), try box.folder("B")]
        guard drives.count == 2 else { return }
        try photoBackup(card: volume.mountPoint, drives: drives, shots: 150, label: exFAT ? "exFAT images" : "folders") {
            volume.remount()
        }
    }

    /// Card and drives on three devices of their own: what the pipeline is
    /// for, the card read while the drives read back.
    @Test("a photo card of 140 files to two drives, card and drives apart")
    func photoCardApart() throws {
        guard let card = RAMVolume(megabytes: 1100), let a = RAMVolume(megabytes: 1100), let b = RAMVolume(megabytes: 1100) else { return }
        try photoBackup(card: card.mountPoint, drives: [a.mountPoint, b.mountPoint], shots: 70, label: "RAM disks") {}
    }

    private func photoBackup(card: URL, drives: [URL], shots: Int, label: String, cool: () -> Void) throws {
        var generator = SystemRandomNumberGenerator()
        var block = [UInt64](repeating: 0, count: 1 << 17)
        for i in block.indices { block[i] = generator.next() }
        let mb = block.withUnsafeBytes { Data($0) }
        let t = local(2026, 9, 21, 23, 30)
        for n in 1...shots {
            for (ext, megabytes) in [("ARW", 12), ("JPG", 2)] {
                let url = card.appendingPathComponent(String(format: "DCIM/100MSDCF/DSC%05d.%@", n, ext))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var data = Data(capacity: megabytes << 20)
                for _ in 0..<megabytes { data.append(mb) }
                data.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(n)) { Data($0) })
                try data.write(to: url)
                try FileManager.default.setAttributes([.modificationDate: t.addingTimeInterval(Double(n))], ofItemAtPath: url.path)
            }
        }
        cool()
        let scan = try CardScanner.scan(card)
        var settings = IngestSettings()
        settings.client = "Kaffi"
        settings.project = "Lexus"
        let sources = [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)]
        let plan = Planner.plan(sources: sources, settings: settings, fixedDay: nil, drives: drives)
        let start = Date()
        let report = Backup.run(plan, drives: drives, isCancelled: { false }) { _ in }
        let seconds = Date().timeIntervalSince(start)
        #expect(report.succeeded, "\(report.failures)")
        let megabytes = Double(report.bytesCopied) / 1_048_576
        print("BENCH photo card \(report.filesCopied) files, \(Int(megabytes)) MB to 2 \(label) in \(String(format: "%.2f", seconds)) s (\(Int(megabytes / seconds)) MB/s of card)")
    }
}
