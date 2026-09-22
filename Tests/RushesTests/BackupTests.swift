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

// RUSHES_BENCH=1 swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/rushes-release --filter bench
@Suite("Bench", .enabled(if: ProcessInfo.processInfo.environment["RUSHES_BENCH"] != nil))
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
}
