import Darwin
import Foundation
import Testing
@testable import Rushes

// The card is formatted on the strength of what the scan saw. A file it
// walked past without a word is a file that is gone in the morning.

@Suite("Scanner")
struct ScannerTests {
    @Test("the camera's housekeeping is walked, and a picture found there is named")
    func housekeepingIsWalked() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: t)
        try box.write("PRIVATE/M4ROOT/GENERAL/STATUS.BIN", in: card, size: 10, date: t)
        try box.write("MISC/VERSION.TXT", in: card, size: 10, date: t)
        try box.write("BACKUP/IMG_0042.JPG", in: card, size: 500, date: t)
        try box.write("MISC/THM/100/DJI_0001.JPG", in: card, size: 50, date: t)

        let scan = try CardScanner.scan(card)

        #expect(scan.photoCount == 1)
        #expect(scan.unknown.isEmpty)
        #expect(scan.setAside.map(\.relativePath) == ["BACKUP/IMG_0042.JPG"])
        #expect(scan.setAside.first?.hiddenBy == "BACKUP")
    }

    /// FAT and exFAT keep a DOS hidden attribute, which the Mac reads as the
    /// hidden flag. A picture carrying it used to be skipped with the dot files.
    @Test("a picture flagged hidden is named, not skipped")
    func hiddenFlagIsNamed() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00002.ARW", in: card, size: 1_000, date: t)
        try box.write("DCIM/100MSDCF/.DS_Store", in: card, size: 10, date: t)
        #expect(chflags(card.appendingPathComponent("DCIM/100MSDCF/DSC00002.ARW").path, UInt32(UF_HIDDEN)) == 0)

        let scan = try CardScanner.scan(card)

        #expect(scan.photoCount == 1)
        #expect(scan.setAside.map(\.name) == ["DSC00002.ARW"])
        #expect(scan.setAside.first?.hiddenBy == "")
        #expect(scan.unknown.isEmpty)
    }

    @Test("a picture set aside keeps the card from being called formatable")
    func setAsideAsksForALook() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: t)
        try box.write("BACKUP/IMG_0042.JPG", in: card, size: 500, date: t)
        let scan = try CardScanner.scan(card)

        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        let plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded)

        let verdict = Verdicts.of(cardID: card.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .check)
        #expect(verdict.sentence.contains("BACKUP"))
        #expect(!verdict.sentence.contains("Tu peux formater"))
    }

    @Test("Rushes' own records and Windows' bin are not walked at all")
    func ignoredFoldersStayIgnored() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: t)
        try box.write("_RUSHES/260921-220000.json", in: card, size: 10, date: t)
        try box.write("$RECYCLE.BIN/DSC00009.JPG", in: card, size: 10, date: t)

        let scan = try CardScanner.scan(card)

        #expect(scan.photoCount == 1)
        #expect(scan.setAside.isEmpty)
        #expect(scan.unknown.isEmpty)
    }
}
