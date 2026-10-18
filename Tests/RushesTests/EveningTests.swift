import Foundation
import Testing
@testable import Rushes

// Version 0.5: the card brought back in the evening, the card emptied of what
// is saved rather than formatted, the name patterns kept under a name, and
// the settings that make no new plan.

@Suite("Evening", .serialized)
struct EveningTests {
    private func settings(client: String = "Kaffi", project: String = "Lexus") -> IngestSettings {
        var s = IngestSettings()
        s.initials = "SR"
        s.client = client
        s.project = project
        s.namePattern = NamePreset.standard.pattern
        return s
    }

    private func source(_ card: URL) throws -> PlanSource {
        PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)
    }

    /// The morning: one card, two shots, backed up under Kaffi · Lexus.
    private func morning(_ box: Sandbox) throws -> (card: URL, drive: URL, plan: IngestPlan, report: BackupReport) {
        let card = try box.folder("CARD")
        let drive = try box.folder("SSD")
        let t = local(2026, 10, 16, 9, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 20_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00002.ARW", in: card, size: 20_000, date: t.addingTimeInterval(60))
        let s = settings()
        var plan = Planner.plan(sources: [try source(card)], settings: s, fixedDay: nil, drives: [drive])
        plan.client = s.client
        plan.project = s.project
        plan.initials = s.initials
        let report = Backup.run(plan, drives: [drive], isCancelled: { false }) { _ in }
        #expect(report.succeeded, "\(report.failures)")
        return (card, drive, plan, report)
    }

    @Test("the journal remembers who a backup was for")
    func startLineSaysTheShoot() throws {
        let box = try Sandbox()
        let m = try morning(box)
        let shoots = DriveJournal.load(m.drive).shoots
        #expect(shoots.count == 1)
        #expect(shoots.first?.client == "Kaffi")
        #expect(shoots.first?.project == "Lexus")
        #expect(shoots.first?.days == [ShootDay(year: 2026, month: 10, day: 16)])
        #expect(shoots.first?.files == 2)
    }

    @Test("the same card back in the evening, the fields typed over, is offered its shoot")
    func cardBroughtBack() throws {
        let box = try Sandbox()
        let m = try morning(box)
        try box.write("DCIM/100MSDCF/DSC00003.ARW", in: m.card, size: 20_000, date: local(2026, 10, 16, 18, 0))

        let other = settings(client: "Renault", project: "Clio")
        let found = try #require(ShootContinuation.find(sources: [try source(m.card)], days: [], settings: other, drives: [m.drive]))
        #expect(found.client == "Kaffi")
        #expect(found.project == "Lexus")
        #expect(found.shotsSaved == 2)
        #expect(!found.matches)

        // Put back, the evening's shot carries on the morning's numbers.
        let same = ShootContinuation.find(sources: [try source(m.card)], days: [], settings: settings(), drives: [m.drive])
        #expect(same?.matches == true)
        let evening = Planner.plan(sources: [try source(m.card)], settings: settings(), fixedDay: nil, drives: [m.drive])
        #expect(evening.toCopy.map(\.baseName) == ["261016_SR_Kaffi_Lexus_0003"])
    }

    @Test("a fresh card of the same day is offered the day's last shoot, another day is not")
    func freshCardSameDay() throws {
        let box = try Sandbox()
        let m = try morning(box)
        let fresh = try box.folder("FRESH")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: fresh, size: 30_000, date: local(2026, 10, 16, 19, 0))
        let other = settings(client: "", project: "")

        let today = ShootContinuation.find(sources: [try source(fresh)], days: [ShootDay(year: 2026, month: 10, day: 16)], settings: other, drives: [m.drive])
        #expect(today?.title == "Kaffi · Lexus")
        #expect(today?.shotsSaved == 0)

        let tomorrow = ShootContinuation.find(sources: [try source(fresh)], days: [ShootDay(year: 2026, month: 10, day: 17)], settings: other, drives: [m.drive])
        #expect(tomorrow == nil)
    }

    @Test("emptying a card deletes what is on every drive, and only that")
    func emptyCard() throws {
        let box = try Sandbox()
        let m = try morning(box)
        // Left on purpose: a kind Rushes does not know, never in the plan.
        try box.write("PRIVATE/SONY/SETTINGS.DAT", in: m.card, size: 100, date: .now)

        let items = CardCleanup.items(cardID: m.card.path, plan: m.plan, report: m.report, drives: [m.drive])
        #expect(items.count == 2)
        let identity = try #require(VolumeWatcher.identity(of: m.card))
        let result = try runBlocking { try await CardCleanup.run(items, card: m.card, identity: identity, avoiding: []) }
        #expect(result.deleted == 2)
        #expect(result.kept.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: m.card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW").path))
        #expect(FileManager.default.fileExists(atPath: m.card.appendingPathComponent("PRIVATE/SONY/SETTINGS.DAT").path))
    }

    @Test("a file changed on the card, or a copy gone from a drive, stays on the card")
    func emptyRefuses() throws {
        let box = try Sandbox()
        let m = try morning(box)
        let items = CardCleanup.items(cardID: m.card.path, plan: m.plan, report: m.report, drives: [m.drive])
        let first = m.card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: m.card, size: 21_000, date: .now)
        let copy = try #require(items.first { $0.source.lastPathComponent == "DSC00002.ARW" }?.copies.first)
        try FileManager.default.removeItem(at: copy)

        let identity = try #require(VolumeWatcher.identity(of: m.card))
        let result = try runBlocking { try await CardCleanup.run(items, card: m.card, identity: identity, avoiding: []) }
        #expect(result.deleted == 0)
        #expect(result.kept.count == 2)
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("another volume's serial deletes nothing")
    func emptyChecksTheCard() throws {
        let box = try Sandbox()
        let m = try morning(box)
        let items = CardCleanup.items(cardID: m.card.path, plan: m.plan, report: m.report, drives: [m.drive])
        #expect(throws: (any Error).self) {
            try runBlocking { try await CardCleanup.run(items, card: m.card, identity: "not-this-card", avoiding: []) }
        }
        #expect(FileManager.default.fileExists(atPath: m.card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW").path))
    }

    @Test("a pattern saved under a name, renamed in place, never a built-in one")
    func savedPresets() {
        var s = IngestSettings()
        #expect(s.savePreset(named: "Mariage", pattern: "{YYMMDD}_{CLIENT}_{NUM}") == "Mariage")
        #expect(s.savePreset(named: "Pub", pattern: "{YYMMDD}_{PROJET}_{NUM}") == "Pub")
        #expect(s.savePreset(named: "Noces", pattern: "{YYMMDD}_{CLIENT}_{NUM}") == "Noces")
        #expect(s.namePresets.map(\.name) == ["Noces", "Pub"])
        #expect(s.savePreset(named: "Standard", pattern: NamePreset.standard.pattern) == nil)
        #expect(s.savePreset(named: "  ", pattern: "{NUM}") == nil)

        let data = try! JSONEncoder().encode(s)
        #expect(try! JSONDecoder().decode(IngestSettings.self, from: data).namePresets == s.namePresets)
    }

    @Test("what a plan never reads makes no new plan")
    func plansLike() {
        let s = settings()
        var t = s
        t.ambiance = .ocean
        t.recentClients = ["Renault"]
        t.namePresets = [SavedNamePreset(name: "x", pattern: "{NUM}")]
        t.measuredThroughput = 1
        #expect(s.plansLike(t))
        t.project = "Clio"
        #expect(!s.plansLike(t))
    }

    @Test("a folder pattern of slashes alone is no folder")
    func slashesAlone() {
        let values = NameValues(day: ShootDay(year: 2026, month: 10, day: 16))
        #expect(NameTemplate("/").renderPath(values) == "")
        #expect(NameTemplate("VIDEO//{YYMMDD}/").renderPath(values) == "VIDEO/261016")
    }
}

/// Waits for async work from a synchronous test.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, any Error>?
}
