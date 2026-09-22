import Foundation
import Testing
@testable import Rushes

// The one sentence that decides whether a card goes back in the camera and
// gets formatted. It is per card, and it is never kinder than the facts.

@Suite("Verdict")
struct VerdictTests {
    private func card(_ box: Sandbox, unknown: Bool = false, locked: Bool = false) throws -> (URL, CardScan) {
        let card = try box.folder("CARD-\(UUID().uuidString.prefix(4))")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00001.JPG", in: card, size: 500, date: t)
        if unknown { try box.write("DCIM/100MSDCF/SETTINGS.OSV", in: card, size: 10, date: t) }
        if locked {
            try box.write("DCIM/101MSDCF/DSC00002.ARW", in: card, size: 1_000, date: t)
            #expect(chmod(card.appendingPathComponent("DCIM/101MSDCF").path, 0) == 0)
        }
        return (card, try CardScanner.scan(card))
    }

    private func settings() -> IngestSettings {
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        return settings
    }

    private func plan(_ url: URL, _ scan: CardScan, _ drive: URL, _ settings: IngestSettings) -> IngestPlan {
        Planner.plan(
            sources: [PlanSource(id: url.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [drive]
        )
    }

    @Test("a card whose every ticked file is verified may be formatted")
    func safe() throws {
        let box = try Sandbox()
        let (url, scan) = try card(box)
        let drive = try box.folder("SSD")
        let plan = plan(url, scan, drive, settings())
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded)

        let verdict = Verdicts.of(cardID: url.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .safe)
        #expect(verdict.sentence.contains("Tu peux formater"))
    }

    /// The card may hold files of a kind nobody listed. They are never copied
    /// and cannot be ticked, so the card is not plainly formattable.
    @Test("a file of an unknown kind asks for a look before formatting")
    func unknownAsksForALook() throws {
        let box = try Sandbox()
        let (url, scan) = try card(box, unknown: true)
        let drive = try box.folder("SSD")
        let plan = plan(url, scan, drive, settings())
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }

        let verdict = Verdicts.of(cardID: url.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .check)
        #expect(verdict.title == "À vérifier")
        #expect(verdict.sentence.contains("OSV"))
        #expect(!verdict.sentence.contains("Tu peux formater"))
    }

    @Test("a card read in part is never formattable")
    func partialRead() throws {
        let box = try Sandbox()
        let (url, scan) = try card(box, locked: true)
        defer { chmod(url.appendingPathComponent("DCIM/101MSDCF").path, 0o755) }
        let drive = try box.folder("SSD")
        let plan = plan(url, scan, drive, settings())
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }

        let verdict = Verdicts.of(cardID: url.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .hold)
        #expect(verdict.sentence.contains("pas été lue entièrement"))
    }

    /// One card failing must not keep another one from being formatted, and a
    /// card whose shots are all already saved is formattable as it stands.
    @Test("each card answers for itself")
    func oneCardPerVerdict() throws {
        let box = try Sandbox()
        let (first, firstScan) = try card(box)
        let (second, secondScan) = try card(box)
        let drive = try box.folder("SSD")
        let plan = Planner.plan(
            sources: [
                PlanSource(id: first.path, volumeName: "A", cameraLabel: "A", groups: firstScan.groups),
                PlanSource(id: second.path, volumeName: "B", cameraLabel: "B", groups: secondScan.groups),
            ],
            settings: settings(), fixedDay: nil, drives: [drive]
        )
        var report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        report.failures = [.init(file: "DCIM/100MSDCF/DSC00001.ARW", message: "illisible", source: second.path)]

        let good = Verdicts.of(cardID: first.path, cardName: "A", scan: firstScan, plan: plan, report: report)
        let bad = Verdicts.of(cardID: second.path, cardName: "B", scan: secondScan, plan: plan, report: report)
        #expect(good.level == .safe)
        #expect(bad.level == .hold)
        #expect(bad.sentence.contains("n'a pas pu être copié"))
    }

    @Test("a backup stopped before the end holds the cards it had left")
    func stoppedBackup() throws {
        let box = try Sandbox()
        let (url, scan) = try card(box)
        let drive = try box.folder("SSD")
        let plan = plan(url, scan, drive, settings())
        var report = BackupReport()
        report.cancelled = true

        let verdict = Verdicts.of(cardID: url.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .hold)
        #expect(verdict.sentence.contains("interrompue"))
    }
}
