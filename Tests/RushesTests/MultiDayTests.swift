import Foundation
import Testing
@testable import Rushes

// A card that holds a few shots of another day beside tonight's (2026-11-23):
// "une ou deux photos qui traînent encore sur la carte SD et ça casse tout".

@Suite("Multi-day cards", .serialized)
struct MultiDayTests {
    private func settings(_ client: String = "Kaffi", _ project: String = "Lexus") -> IngestSettings {
        var s = IngestSettings()
        s.initials = "SR"
        s.client = client
        s.project = project
        s.namePattern = NamePreset.standard.pattern
        return s
    }

    private let old = local(2026, 11, 14, 15, 0)
    private let night = local(2026, 11, 23, 21, 0)
    private let tonight = ShootDay(year: 2026, month: 11, day: 23)
    private let theFourteenth = ShootDay(year: 2026, month: 11, day: 14)

    private func writeOld(_ card: URL, _ box: Sandbox) throws {
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: old)
        try box.write("DCIM/100MSDCF/DSC00002.ARW", in: card, size: 1_000, date: old.addingTimeInterval(60))
    }

    private func writeTonight(_ card: URL, _ box: Sandbox, count: Int = 300) throws {
        for i in 3..<(3 + count) {
            try box.write(String(format: "DCIM/100MSDCF/DSC%05d.ARW", i), in: card, size: 1_000, date: night.addingTimeInterval(Double(i) * 10))
        }
    }

    /// 300 shots of tonight and 2 of nine days earlier, on one card.
    private func card(_ box: Sandbox) throws -> URL {
        let card = try box.folder("CARD")
        try writeOld(card, box)
        try writeTonight(card, box)
        return card
    }

    private func source(_ card: URL) throws -> PlanSource {
        PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)
    }

    private func names(_ plan: IngestPlan, day: ShootDay? = nil) -> [String] {
        plan.toCopy.filter { day == nil || $0.day == day }.map(\.baseName)
    }

    // MARK: Telling the days apart

    @Test("two photos nine days before tonight's three hundred are told apart")
    func spread() throws {
        let box = try Sandbox()
        let spread = DaySpread.of(try source(try card(box)).groups, cutoffHour: 5)
        #expect(spread.main == [tonight])
        #expect(spread.target == tonight)
        #expect(spread.stragglers.map(\.day) == [theFourteenth])
        #expect(spread.stragglers.first?.described == "2 photos")
    }

    @Test("a shoot of several days, a day off included, is one shoot; a night keeps its day")
    func oneShoot() {
        let groups = [
            local(2026, 11, 20, 10, 0), local(2026, 11, 21, 10, 0), local(2026, 11, 23, 10, 0),
            local(2026, 11, 24, 2, 0), // past midnight, still the 23rd
        ].enumerated().map { i, t in Grouping.group([file("DCIM/100MSDCF/DSC0000\(i).ARW", at: t)]).groups[0] }
        let spread = DaySpread.of(groups, cutoffHour: 5)
        #expect(spread.stragglers.isEmpty)
        #expect(spread.main.count == 3)
    }

    @Test("two runs of as many shots: the latest is the shoot")
    func tie() {
        let groups = [local(2026, 11, 1, 10, 0), local(2026, 11, 23, 10, 0)].enumerated().map { i, t in
            Grouping.group([file("DCIM/100MSDCF/DSC0000\(i).ARW", at: t)]).groups[0]
        }
        let spread = DaySpread.of(groups, cutoffHour: 5)
        #expect(spread.main == [tonight])
        #expect(spread.stragglers.map(\.day) == [ShootDay(year: 2026, month: 11, day: 1)])
    }

    // MARK: Filing

    @Test("by default the old shots keep their day, and tonight starts at 0001")
    func ownDay() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        let plan = Planner.plan(sources: [try source(try card(box))], settings: settings(), fixedDay: nil, drives: [drive])
        #expect(plan.toCopy.count == 302)
        #expect(names(plan, day: theFourteenth) == ["261114_SR_Kaffi_Lexus_0001", "261114_SR_Kaffi_Lexus_0002"])
        #expect(names(plan, day: tonight).first == "261123_SR_Kaffi_Lexus_0001")
        #expect(names(plan, day: tonight).last == "261123_SR_Kaffi_Lexus_0300")
        #expect(plan.spread.stragglers.first?.folder == "261114_Kaffi_Lexus")
    }

    @Test("a day fixed by hand is the shoot's: it no longer takes the old shots in as 0001 and 0002")
    func fixedDayLeavesThemAlone() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        let plan = Planner.plan(sources: [try source(try card(box))], settings: settings(), fixedDay: tonight, drives: [drive])
        #expect(names(plan, day: tonight).first == "261123_SR_Kaffi_Lexus_0001")
        #expect(names(plan, day: tonight).count == 300)
        #expect(names(plan, day: theFourteenth).count == 2)
    }

    @Test("filed with the shoot, they take the numbers after tonight's")
    func withShoot() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        let src = try source(try card(box))
        let plan = Planner.plan(sources: [src], settings: settings(), fixedDay: nil, dayFiling: [theFourteenth: .withShoot], drives: [drive])
        #expect(plan.shootFolders == ["261123_Kaffi_Lexus"])
        let all = names(plan)
        #expect(all.count == 302)
        #expect(all.first == "261123_SR_Kaffi_Lexus_0001")
        #expect(all.suffix(2) == ["261123_SR_Kaffi_Lexus_0301", "261123_SR_Kaffi_Lexus_0302"])
        let last = plan.toCopy.suffix(2).map { $0.group.anchor.name }
        #expect(last == ["DSC00001.ARW", "DSC00002.ARW"])

        // With a day fixed by hand, to that day.
        let fixed = ShootDay(year: 2026, month: 11, day: 22)
        let moved = Planner.plan(sources: [src], settings: settings(), fixedDay: fixed, dayFiling: [theFourteenth: .withShoot], drives: [drive])
        #expect(Set(moved.toCopy.map(\.day)) == [fixed])
    }

    @Test("numbers carry on after what the drive holds, the old shots after tonight's")
    func carriesOn() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        // The first card of tonight, already backed up.
        let first = try box.folder("FIRST")
        for i in 1...10 {
            try box.write(String(format: "DCIM/100MSDCF/DSC%05d.ARW", i), in: first, size: 2_000, date: night.addingTimeInterval(Double(-i)))
        }
        let report = Backup.run(Planner.plan(sources: [try source(first)], settings: settings(), fixedDay: nil, drives: [drive]),
                                drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded)

        let plan = Planner.plan(sources: [try source(try card(box))], settings: settings(), fixedDay: nil,
                                dayFiling: [theFourteenth: .withShoot], drives: [drive])
        #expect(names(plan).first == "261123_SR_Kaffi_Lexus_0011")
        #expect(names(plan).last == "261123_SR_Kaffi_Lexus_0312")
    }

    @Test("left on the card: not copied, no number, and the card is to be checked, never formatable")
    func leave() throws {
        let box = try Sandbox()
        let drive = try box.folder("SSD")
        let url = try card(box)
        let scan = try CardScanner.scan(url)
        let plan = Planner.plan(sources: [PlanSource(id: url.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
                                settings: settings(), fixedDay: nil, dayFiling: [theFourteenth: .leave], drives: [drive])
        #expect(plan.toCopy.count == 300)
        #expect(plan.leftOnCard == 2)
        #expect(plan.shootFolders == ["261123_Kaffi_Lexus"])
        #expect(plan.days == [tonight])

        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded)
        #expect(!FileManager.default.fileExists(atPath: drive.appendingPathComponent("261114_Kaffi_Lexus").path))
        let verdict = Verdicts.of(cardID: url.path, cardName: "CARD", scan: scan, plan: plan, report: report)
        #expect(verdict.level == .check)
        #expect(verdict.sentence.contains("2 photos du"))
        #expect(verdict.sentence.contains("14 novembre"))

        // Nothing it left is offered for deletion.
        let items = CardCleanup.items(cardID: url.path, plan: plan, report: report, drives: [drive])
        #expect(items.count == 300)
        #expect(!items.contains { $0.source.lastPathComponent == "DSC00001.ARW" })

        let rows = PreviewRows(plan: plan, sources: [PlanSource(id: url.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)], settings: settings())
        #expect(rows.leftOut.filter { $0.note.contains("laissée sur la carte") }.count == 2)
    }

    // MARK: Already saved

    /// The 14th backed up under Renault · Clio, then tonight's shots added to
    /// the same card: the case of a card never formatted.
    private func savedBefore(_ box: Sandbox) throws -> (card: URL, drive: URL) {
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        try writeOld(card, box)
        let s = settings("Renault", "Clio")
        var plan = Planner.plan(sources: [try source(card)], settings: s, fixedDay: nil, drives: [drive])
        plan.client = s.client
        plan.project = s.project
        #expect(Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }.succeeded)
        try writeTonight(card, box)
        return (card, drive)
    }

    @Test("old shots already on every drive are skipped and said so, and make no folder")
    func alreadySaved() throws {
        let box = try Sandbox()
        let (card, drive) = try savedBefore(box)
        let plan = Planner.plan(sources: [try source(card)], settings: settings(), fixedDay: nil, drives: [drive])
        #expect(plan.alreadyCopied == 2)
        #expect(plan.toCopy.count == 300)
        // Before: "261114_Kaffi_Lexus" was listed too, a folder for nothing.
        #expect(plan.shootFolders == ["261123_Kaffi_Lexus"])
        let straggler = try #require(plan.spread.stragglers.first)
        #expect(straggler.allSaved)
        #expect(straggler.savedIn?.hasPrefix("261114_Renault_Clio") == true)

        // Left on the card by choice, saved all the same: the card is formatable.
        let scan = try CardScanner.scan(card)
        let leaving = Planner.plan(sources: [try source(card)], settings: settings(), fixedDay: nil,
                                   dayFiling: [theFourteenth: .leave], drives: [drive])
        #expect(leaving.alreadyCopied == 2)
        #expect(leaving.leftOnCard == 0)
        let report = Backup.run(leaving, drives: [drive], isCancelled: { false }) { _ in }
        #expect(Verdicts.of(cardID: card.path, cardName: "CARD", scan: scan, plan: leaving, report: report).level == .safe)
    }

    @Test("the shoot the old shots were saved in is not offered for tonight's")
    func continuation() throws {
        let box = try Sandbox()
        let (card, drive) = try savedBefore(box)
        let src = try source(card)
        let s = settings()
        let plan = Planner.plan(sources: [src], settings: s, fixedDay: nil, drives: [drive])
        // Before: Renault · Clio, "2 prises de ces cartes sont déjà dedans",
        // and one click filed tonight's 300 under it.
        let found = ShootContinuation.find(sources: [src], days: plan.spread.main, settings: s, drives: [drive], spread: plan.spread)
        #expect(found == nil)
        let unguarded = ShootContinuation.find(sources: [src], days: [tonight, theFourteenth], settings: s, drives: [drive])
        #expect(unguarded?.client == "Renault")
    }
}
