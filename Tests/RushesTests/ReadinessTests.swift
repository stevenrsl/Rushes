import Foundation
import Testing
@testable import Rushes

// The gate before ⌘↩: each reason is a way the night would go wrong.

@Suite("Readiness")
struct ReadinessTests {
    private func settings() -> IngestSettings {
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        return settings
    }

    private func plan(_ settings: IngestSettings, size: Int = 1_000) throws -> (IngestPlan, Sandbox) {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: size, date: local(2026, 9, 21, 22, 0))
        let scan = try CardScanner.scan(card)
        let plan = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: scan.groups)],
            settings: settings, fixedDay: nil, drives: [try box.folder("SSD")]
        )
        return (plan, box)
    }

    private func drive(_ name: String, volume: String? = nil, free: Int64? = 1 << 40, fs: String = "apfs", online: Bool = true) -> Readiness.Drive {
        .init(name: name, isOnline: online, available: free, fileSystem: fs, volume: volume ?? "/Volumes/\(name)")
    }

    private func gate(_ plan: IngestPlan, _ settings: IngestSettings, drives: [Readiness.Drive], cards: Int = 1, scanning: Bool = false, planning: Bool = false, noLetter: Bool = false) -> [String] {
        Readiness(cards: cards, scanning: scanning, planning: planning, ready: cards, cardWithoutLetter: noLetter,
                  drives: drives, settings: settings, plan: plan).blockers
    }

    @Test("a card, a drive and a name: nothing holds the button")
    func ready() throws {
        let s = settings()
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: [drive("SSD-A"), drive("SSD-B")]).isEmpty)
    }

    @Test("the card being read, or the plan not current, comes first")
    func stateComesFirst() throws {
        let s = settings()
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: [drive("SSD")], cards: 0).first == "Insère une carte ou ajoute un dossier.")
        #expect(gate(plan, s, drives: [drive("SSD")], scanning: true).first == "Lecture des cartes en cours…")
        #expect(gate(plan, s, drives: [drive("SSD")], planning: true).first == "Préparation de l'aperçu…")
    }

    @Test("two folders on one disk are one copy")
    func sameDiskTwice() throws {
        let s = settings()
        let (plan, _) = try plan(s)
        let reasons = gate(plan, s, drives: [drive("Rushes", volume: "/Volumes/T7"), drive("Backup", volume: "/Volumes/T7")])
        #expect(reasons.contains { $0.contains("sur le même disque") })
    }

    @Test("a drive needs the bytes and a margin")
    func spaceMargin() throws {
        let s = settings()
        let (plan, _) = try plan(s)
        let needed = plan.bytesToCopy + Readiness.margin(for: plan.bytesToCopy)
        #expect(gate(plan, s, drives: [drive("SSD", free: needed)]).isEmpty)
        #expect(gate(plan, s, drives: [drive("SSD", free: needed - 1)]).contains { $0.hasPrefix("Pas assez de place") })
    }

    @Test("a drive not plugged in, and none at all, are said")
    func drivesMissing() throws {
        let s = settings()
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: []).contains("Choisis un disque de destination."))
        #expect(gate(plan, s, drives: [drive("SSD", online: false)]).contains("« SSD » n'est pas branché."))
    }

    @Test("a field is missing only if the name or the folders use it")
    func missingFieldOnlyIfUsed() throws {
        var s = settings()
        s.initials = ""
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: [drive("SSD")]).contains("Il manque tes initiales."))
        s.namePattern = "{YYMMDD}_{CLIENT}_{NUM}"
        #expect(!gate(plan, s, drives: [drive("SSD")]).contains("Il manque tes initiales."))
    }

    @Test("a camera letter is wanted only when {CAM} is used")
    func cameraLetter() throws {
        var s = settings()
        let (plan, _) = try plan(s)
        #expect(!gate(plan, s, drives: [drive("SSD")], noLetter: true).contains { $0.contains("lettre de caméra") })
        s.namePattern = NamePreset.cameraLast.pattern
        #expect(gate(plan, s, drives: [drive("SSD")], noLetter: true).contains("Une carte n'a pas de lettre de caméra."))
    }

    @Test("a name whose partial would pass 255 bytes is refused before the night")
    func partialNameTooLong() throws {
        var s = settings()
        s.project = String(repeating: "p", count: 230)
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: [drive("SSD")]).contains { $0.hasSuffix("raccourcis le modèle de nom.") })
    }

    @Test("a pattern with neither {NUM} nor {ORIG} would give two photos one name")
    func uniquePattern() throws {
        var s = settings()
        s.namePattern = "{YYMMDD}_{CLIENT}"
        let (plan, _) = try plan(s)
        #expect(gate(plan, s, drives: [drive("SSD")]).contains { $0.hasPrefix("Le modèle doit contenir") })
    }

    @Test("everything saved is said as such, and only when nothing else is wrong")
    func allSaved() throws {
        let s = settings()
        let (plan, box) = try plan(s)
        let ssd = box.root.appendingPathComponent("SSD")
        _ = Backup.run(plan, drives: [ssd], isCancelled: { false }) { _ in }
        let card = box.root.appendingPathComponent("CARD")
        let again = Planner.plan(
            sources: [PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)],
            settings: s, fixedDay: nil, drives: [ssd]
        )
        #expect(gate(again, s, drives: [drive("SSD")]) == ["Tout est déjà sauvegardé sur chaque disque."])
    }
}
