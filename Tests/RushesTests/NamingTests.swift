import Foundation
import Testing
@testable import Rushes

func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

@Suite("Naming")
struct NamingTests {
    @Test("the model: YYMMDD_XX_Client_Projet_000x")
    func model() {
        let values = NameValues(day: ShootDay(year: 2026, month: 9, day: 21), initials: "SR", client: "Kaffi", project: "Lexus", number: 7)
        #expect(NameTemplate(NamePreset.standard.pattern).render(values) == "260921_SR_Kaffi_Lexus_0007")
        #expect(NameTemplate(NamePreset.longDate.pattern).render(values) == "20260921_SR_Kaffi_Lexus_0007")
        var cam = values
        cam.camera = "B"
        #expect(NameTemplate(NamePreset.multicam.pattern).render(cam) == "260921_SR_Kaffi_Lexus_B0007")
    }

    @Test("clients and projects are made safe for a name")
    func sanitizing() {
        #expect(Sanitize.field("Café d'Été") == "Cafe-dEte")
        #expect(Sanitize.field("Kaffi_Lexus RX  500") == "Kaffi_Lexus-RX-500")
        #expect(Sanitize.field("  Cœur / Été  ") == "Coeur-Ete")
        #expect(Sanitize.code("s.r.") == "SR")
        #expect(Sanitize.code("a_1") == "A1")
        #expect(Sanitize.fileName("a/b:c") == "a-b-c")
    }

    @Test("an underscore typed in a field is kept")
    func underscoreKept() {
        #expect(Sanitize.field("RX_500h") == "RX_500h")
        #expect(Sanitize.field("RX_500H") == "RX_500H")
        #expect(Sanitize.field("RX _ 500h") == "RX_500h")
        #expect(Sanitize.field("_Kaffi__RX_") == "Kaffi_RX")
        let values = NameValues(day: ShootDay(year: 2026, month: 9, day: 21), initials: "SR", client: Sanitize.field("Kaffi"),
                                project: Sanitize.field("RX_500h"), number: 1)
        #expect(NameTemplate(NamePreset.standard.pattern).render(values) == "260921_SR_Kaffi_RX_500h_0001")
        #expect(NameTemplate(IngestSettings.defaultFolderPattern).renderPath(values) == "260921_Kaffi_RX_500h")
    }

    @Test("an empty field leaves no double separator")
    func emptyField() {
        let values = NameValues(day: ShootDay(year: 2026, month: 9, day: 21), initials: "SR", client: "", project: "Air", number: 1)
        #expect(NameTemplate(NamePreset.standard.pattern).render(values) == "260921_SR_Air_0001")
    }

    @Test("unknown braces stay as typed; aliases are understood")
    func parsing() {
        let t = NameTemplate("{DATE}-{project}_{FOO}_{N}")
        #expect(t.tokens == [.yymmdd, .project, .number])
        let values = NameValues(day: ShootDay(year: 2026, month: 1, day: 2), project: "X", number: 3, padding: 3)
        #expect(t.render(values) == "260102-X_{FOO}_003")
    }

    @Test("a night shoot keeps its day until the cutoff")
    func nightShoot() {
        #expect(ShootDay(date: local(2026, 9, 22, 2, 40), cutoffHour: 5) == ShootDay(year: 2026, month: 9, day: 21))
        #expect(ShootDay(date: local(2026, 9, 22, 5, 1), cutoffHour: 5) == ShootDay(year: 2026, month: 9, day: 22))
        #expect(ShootDay(date: local(2026, 9, 22, 2, 40), cutoffHour: 0) == ShootDay(year: 2026, month: 9, day: 22))
        #expect(ShootDay(date: local(2026, 1, 1, 1, 0), cutoffHour: 5) == ShootDay(year: 2025, month: 12, day: 31))
    }

    @Test("the counter expression finds numbers made by the same pattern only")
    func counterExpression() {
        let t = NameTemplate(NamePreset.original.pattern)
        let values = NameValues(day: ShootDay(year: 2026, month: 9, day: 21), initials: "SR", client: "Kaffi", project: "Lexus")
        let expression = t.counterExpression(values)!
        func number(_ stem: String) -> Int? {
            guard let m = expression.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  let r = Range(m.range(at: 1), in: stem) else { return nil }
            return Int(stem[r])
        }
        #expect(number("260921_SR_Kaffi_Lexus_0042_DSC01234") == 42)
        #expect(number("260921_SR_Kaffi_Other_0099_DSC01234") == nil)
        #expect(number("260922_SR_Kaffi_Lexus_0099_DSC01234") == nil)
    }

    @Test("folders by type, sidecars beside their anchor")
    func layout() {
        let v = NameValues(day: ShootDay(year: 2026, month: 9, day: 21), camera: "B")
        let byType = FolderPreset.byType.layout
        #expect(byType.folder(for: .raw, anchor: .raw, values: v) == "PHOTO/RAW")
        #expect(byType.folder(for: .sidecar, anchor: .raw, values: v) == "PHOTO/RAW")
        #expect(byType.folder(for: .sidecar, anchor: .video, values: v) == "VIDEO")
        #expect(byType.folder(for: .proxy, anchor: .video, values: v) == "VIDEO/PROXY")
        #expect(FolderPreset.typeOnly.layout.folder(for: .jpeg, anchor: .raw, values: v) == "JPG")
        #expect(FolderPreset.flat.layout.folder(for: .video, anchor: .video, values: v) == "")
        #expect(FolderPreset.byCamera.layout.folder(for: .proxy, anchor: .video, values: v) == "VIDEO/B/PROXY")
        #expect(FolderPreset.photoVideo.layout.folder(for: .sidecar, anchor: .jpeg, values: v) == "PHOTO")
        var typed = byType
        typed.video = "/VIDEO/{CAM}/../{YYMMDD}/"
        #expect(typed.folder(for: .video, anchor: .video, values: v) == "VIDEO/B/260921")
        #expect(typed.uses(.camera))
        #expect(!byType.uses(.camera))
    }

    @Test("a layout saved by name by the first version reads as its preset")
    func oldLayout() throws {
        let old = try JSONDecoder().decode(IngestSettings.self, from: Data(#"{"layout":"typeOnly"}"#.utf8))
        #expect(old.layout == FolderPreset.typeOnly.layout)
        var s = IngestSettings()
        s.layout.audio = "SON/{CAM}"
        let decoded = try JSONDecoder().decode(IngestSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.layout.audio == "SON/{CAM}")
        #expect(FolderPreset.matching(decoded.layout) == nil)
    }

    @Test("EXIF dates in the camera's format")
    func exifDates() {
        #expect(CaptureDates.parse("2026:09:21 23:41:07") == local(2026, 9, 21, 23, 41, 7))
        #expect(CaptureDates.parse("0000:00:00 00:00:00") == nil)
        #expect(CaptureDates.displayName(make: "SONY", model: "ILCE-7M4") == "Sony ILCE-7M4")
        #expect(CaptureDates.displayName(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(CaptureDates.displayName(make: "NIKON CORPORATION", model: "NIKON Z 8") == "Nikon Z 8")
    }
}
