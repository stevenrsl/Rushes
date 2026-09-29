import Foundation
import Testing
@testable import Rushes

@Suite("Report")
struct ReportTests {
    @Test("the report lists every file, the camera's name beside the new one, and each card's verdict")
    func reportSaysEverything() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 2_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00001.JPG", in: card, size: 500, date: t)
        let scan = try CardScanner.scan(card)
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Café <Été>"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        let plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "A7IV", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        let verdict = Verdicts.of(cardID: card.path, cardName: "A7IV", scan: scan, plan: plan, report: report)
        let (folder, entries) = try #require(report.entries.first)

        let html = TransferReport.html(
            shoot: folder, report: report, entries: entries,
            cards: [.init(name: verdict.cardName, title: verdict.title, sentence: verdict.sentence, level: "safe")],
            drives: ["SSD"], version: "0.2"
        )

        #expect(entries.count == 2)
        #expect(html.contains("DCIM/100MSDCF/DSC00001.ARW"))
        #expect(html.contains("260921_SR_Cafe-Ete_Lexus_0001.ARW"))
        #expect(html.contains("Formatable"))
        #expect(html.contains(entries[0].xxh64))
        #expect(!html.contains("<script"))
        #expect(TransferReport.escape("<a href='x'>&") == "&lt;a href=&#39;x&#39;&gt;&amp;")

        if let out = ProcessInfo.processInfo.environment["RUSHES_REPORT_SAMPLE"] {
            try Data(html.utf8).write(to: URL(fileURLWithPath: out))
        }
    }
}
