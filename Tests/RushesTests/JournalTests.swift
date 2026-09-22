import Foundation
import Testing
@testable import Rushes

// The journal is what a backup leaves behind while it runs, rather than when
// it ends: the night it is cut off, the night the client is renamed, and the
// night the drive was emptied between two cards.

@Suite("Journal", .serialized)
struct JournalTests {
    /// Making a card, backing it up once, and coming back to it the next night
    /// with something changed in between.
    private func firstNight(_ box: Sandbox, client: String = "Kaffi") throws -> (card: URL, drive: URL, settings: IngestSettings, report: BackupReport) {
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 20_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00002.ARW", in: card, size: 20_000, date: t.addingTimeInterval(60))
        try box.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", in: card, size: 30_000, date: t.addingTimeInterval(120))

        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = client
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        let plan = try plan(card, drive, settings)
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded, "\(report.failures)")
        return (card, drive, settings, report)
    }

    private func plan(_ card: URL, _ drive: URL, _ settings: IngestSettings) throws -> IngestPlan {
        let scan = try CardScanner.scan(card)
        return Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
    }

    @Test("a card kept for another client is recognised under the client it was saved as")
    func recognisedAcrossFolders() throws {
        let box = try Sandbox()
        let night = try firstNight(box)

        // The next night, the same card is still in the camera and the shoot
        // is for someone else. The manifests of tonight's folder know nothing
        // of yesterday's shots; the drive's journal does.
        var settings = night.settings
        settings.client = "Renault"
        let next = try plan(night.card, night.drive, settings)

        #expect(next.alreadyCopied == 3)
        #expect(next.toCopy.isEmpty)
        #expect(next.groups.allSatisfy { $0.savedIn?.contains("Kaffi") == true })
    }

    @Test("a backup that never ended is resumed, even with the setting off")
    func unfinishedBackupIsResumed() throws {
        let box = try Sandbox()
        let night = try firstNight(box)

        // A backup cut off leaves its opening line with no closing one. The
        // app may well have been killed since: nothing is kept in memory.
        try Journal.append(
            [JournalLine(kind: .start, backup: "cut-off", at: Date())],
            on: night.drive
        )
        var settings = night.settings
        settings.skipAlreadyCopied = false
        let next = try plan(night.card, night.drive, settings)

        #expect(next.alreadyCopied == 3)
        #expect(next.toCopy.isEmpty)
    }

    @Test("a number given once is never given again, even after the drive is emptied")
    func numbersAreNeverReused() throws {
        let box = try Sandbox()
        let night = try firstNight(box)

        // The shoot is moved to an archive and the drive emptied for the trip,
        // which is what the second card of the night meets.
        try FileManager.default.removeItem(at: night.drive.appendingPathComponent("260921_Kaffi_Lexus/PHOTO"))
        try FileManager.default.removeItem(at: night.drive.appendingPathComponent("260921_Kaffi_Lexus/VIDEO"))

        let second = try box.folder("CARD2")
        try box.write("DCIM/100MSDCF/DSC00009.ARW", in: second, size: 20_000, date: local(2026, 9, 21, 23, 0))
        let scan = try CardScanner.scan(second)
        let plan = Planner.plan(
            sources: [PlanSource(id: second.path, volumeName: "CARD2", cameraLabel: "A", groups: scan.groups)],
            settings: night.settings, fixedDay: nil, drives: [night.drive]
        )

        // 0001 and 0002 named two other photos last night; the client asking
        // for "0002" must never find two of them.
        #expect(plan.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus_0003"])
    }

    @Test("a line cut off in the middle does not cost the lines above it")
    func brokenLineIsSkipped() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        try Journal.append([
            JournalLine(kind: .start, backup: "a", at: Date()),
            JournalLine(kind: .file, backup: "a", at: Date(), path: "shoot/A_0001.ARW", shoot: "shoot",
                        fingerprint: "fp1", xxh64: "0", size: 4),
            JournalLine(kind: .end, backup: "a", at: Date()),
        ], on: drive)
        let handle = try FileHandle(forWritingTo: Journal.url(on: drive))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":\"file\",\"backup\"".utf8))
        try handle.close()

        let journal = DriveJournal.load(drive)
        #expect(journal.saved["fp1"]?.path == "shoot/A_0001.ARW")
        #expect(!journal.interrupted)

        // And the file has to be there for the shot to count as saved.
        #expect(!journal.holds("fp1", on: drive))
        try box.write("shoot/A_0001.ARW", in: drive, size: 4, date: Date())
        #expect(journal.holds("fp1", on: drive))
    }
}
