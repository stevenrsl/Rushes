import Foundation
import Testing
@testable import Rushes

@Suite("ASC MHL", .serialized)
struct MHLTests {
    /// Computed with the reference algorithm, which reproduces the chain of
    /// github.com/ascmitc/mhl's own examples.
    @Test("the C4 id matches the reference")
    func c4Vectors() {
        #expect(ASCMHL.c4(Data()) == "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
        #expect(ASCMHL.c4(Data("Rushes".utf8)) == "c458GMLJdtcmz5WdF9rfnwx4iDK47wYUB7sGXaoJV3wKfic8QkTKss5P8Nx2czyE7vf6BZjwzVaZqmm42gTuA32g1q")
        #expect(ASCMHL.c4(Data("Rushes".utf8)).count == 90)
    }

    private func night(_ box: Sandbox, _ card: URL, _ drive: URL, first: Int) throws -> BackupReport {
        let t = local(2026, 9, 21, 22, 0)
        for n in first..<(first + 2) {
            try box.write(String(format: "DCIM/100MSDCF/DSC%05d.ARW", n), in: card, size: 10_000, date: t.addingTimeInterval(Double(n) * 60))
        }
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        var plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
        plan.writesMHL = true
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded, "\(report.failures)")
        return report
    }

    @Test("each backup adds a generation, sealed in the chain, and never rewrites one")
    func generations() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        _ = try night(box, card, drive, first: 1)
        let folder = drive.appendingPathComponent("260921_Kaffi_Lexus/ascmhl")
        let firstList = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasPrefix("0001_260921_Kaffi_Lexus_") && $0.hasSuffix("Z.mhl") })
        let firstBytes = try Data(contentsOf: folder.appendingPathComponent(firstList))

        // A second card the same night, into the same folder.
        _ = try night(box, card, drive, first: 3)

        let chain = ASCMHL.readChain(folder.appendingPathComponent(ASCMHL.chainName))
        #expect(chain.map(\.sequence) == [1, 2])
        #expect(chain[0].path == firstList)
        #expect(chain[0].c4 == ASCMHL.c4(firstBytes))
        #expect(try Data(contentsOf: folder.appendingPathComponent(firstList)) == firstBytes)
        let second = try Data(contentsOf: folder.appendingPathComponent(chain[1].path))
        #expect(chain[1].c4 == ASCMHL.c4(second))

        let text = String(decoding: second, as: UTF8.self)
        #expect(text.contains("<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">"))
        #expect(text.contains("PHOTO/RAW/260921_SR_Kaffi_Lexus_0003.ARW"))
        #expect(!text.contains("0001.ARW"))
        let hash = try Copier.hash(of: drive.appendingPathComponent("260921_Kaffi_Lexus/PHOTO/RAW/260921_SR_Kaffi_Lexus_0003.ARW"))
        #expect(text.contains(">\(hash)</xxh64>"))

        if let out = ProcessInfo.processInfo.environment["RUSHES_MHL_SAMPLE"] {
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.copyItem(at: folder, to: URL(fileURLWithPath: out))
        }
    }

    @Test("off by default, nothing is written")
    func offByDefault() throws {
        #expect(!IngestSettings().writeMHL)
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: Date())
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        let plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
        _ = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        let shoot = try #require(plan.shootFolders.first)
        #expect(!FileManager.default.fileExists(atPath: drive.appendingPathComponent(shoot).appendingPathComponent("ascmhl").path))
    }
}
