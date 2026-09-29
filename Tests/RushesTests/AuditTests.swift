import Foundation
import Testing
@testable import Rushes

// A drive read back months later against its own records: what is missing,
// what changed size, what no longer reads the same. Only ever read.

@Suite("Audit", .serialized)
struct AuditTests {
    private func archive(_ box: Sandbox) throws -> (drive: URL, shoot: URL, entries: [Manifest.Entry]) {
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 22, 0)
        for n in 1...3 {
            try box.write(String(format: "DCIM/100MSDCF/DSC%05d.ARW", n), in: card, size: 30_000, date: t.addingTimeInterval(Double(n) * 60))
        }
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        let scan = try CardScanner.scan(card)
        let plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded)
        let (folder, entries) = try #require(report.entries.first)
        return (drive, drive.appendingPathComponent(folder), entries)
    }

    @Test("a drive that still holds everything is said to")
    func intactDrive() throws {
        let box = try Sandbox()
        let (drive, _, _) = try archive(box)
        let report = Audit.run(drive, isCancelled: { false }) { _ in }
        #expect(report.records == 1)
        #expect(report.checked == 3)
        #expect(report.problems.isEmpty)
        #expect(report.succeeded)
    }

    @Test("a file gone, one cut short and one that reads differently are each named")
    func damagedDrive() throws {
        let box = try Sandbox()
        let (drive, shoot, entries) = try archive(box)
        let paths = entries.map(\.path).sorted()
        try FileManager.default.removeItem(at: shoot.appendingPathComponent(paths[0]))
        #expect(truncate(shoot.appendingPathComponent(paths[1]).path, 100) == 0)
        // Same size, one byte flipped: only reading it again can tell.
        let third = shoot.appendingPathComponent(paths[2])
        var data = try Data(contentsOf: third)
        data[1234] ^= 0xFF
        try data.write(to: third)

        let report = Audit.run(drive, isCancelled: { false }) { _ in }

        #expect(report.checked == 3)
        #expect(!report.succeeded)
        let kinds = Dictionary(uniqueKeysWithValues: report.problems.map { (($0.item.path as NSString).lastPathComponent, $0.kind) })
        #expect(kinds[(paths[0] as NSString).lastPathComponent] == .missing)
        #expect(kinds[(paths[1] as NSString).lastPathComponent] == .resized(100))
        if case .changed = kinds[(paths[2] as NSString).lastPathComponent] {} else { Issue.record("the flipped byte was not seen") }
    }

    @Test("one shoot folder can be checked on its own, moved to an archive")
    func shootFolderAlone() throws {
        let box = try Sandbox()
        let (_, shoot, _) = try archive(box)
        let archive = try box.folder("ARCHIVE").appendingPathComponent(shoot.lastPathComponent)
        try FileManager.default.copyItem(at: shoot, to: archive)

        let report = Audit.run(archive, isCancelled: { false }) { _ in }
        #expect(report.records == 1)
        #expect(report.checked == 3)
        #expect(report.succeeded)
    }

    @Test("a folder with no record says so, instead of calling itself intact")
    func noRecords() throws {
        let box = try Sandbox()
        let folder = try box.folder("NOTHING")
        try box.write("photo.jpg", in: folder, size: 10, date: Date())
        let report = Audit.run(folder, isCancelled: { false }) { _ in }
        #expect(report.records == 0)
        #expect(!report.succeeded)
    }
}
