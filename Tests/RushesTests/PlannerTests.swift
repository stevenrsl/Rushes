import Foundation
import Testing
@testable import Rushes

@Suite("Planner")
struct PlannerTests {
    var settings: IngestSettings {
        var s = IngestSettings()
        s.initials = "sr"
        s.client = "Kaffi"
        s.project = "Lexus RX"
        // The behaviour these tests were written for, not Steven's defaults.
        s.namePattern = NamePreset.standard.pattern
        s.sharedCounter = true
        s.skipAlreadyCopied = true
        s.kindChoices = [FileKind(role: .sidecar, ext: "XML").id: true]
        return s
    }

    let drive = URL(fileURLWithPath: "/Volumes/SSD")

    func source(_ id: String, _ label: String, _ files: [MediaFile]) -> PlanSource {
        PlanSource(id: id, volumeName: id, cameraLabel: label, groups: Grouping.group(files).groups)
    }

    func paths(_ plan: IngestPlan) -> [String] {
        plan.toCopy.flatMap { $0.files.map(\.relativePath) }
    }

    @Test("a RAW and its JPEG share a number and a name, each in its folder")
    func sisters() {
        let t = local(2026, 9, 21, 20, 0)
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100MSDCF/DSC00001.ARW", at: t),
                file("DCIM/100MSDCF/DSC00001.JPG", at: t),
                file("DCIM/100MSDCF/DSC00002.JPG", at: t.addingTimeInterval(1)),
            ])],
            settings: settings, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(paths(plan) == [
            "260921_Kaffi_Lexus-RX/PHOTO/RAW/260921_SR_Kaffi_Lexus-RX_0001.ARW",
            "260921_Kaffi_Lexus-RX/PHOTO/JPG/260921_SR_Kaffi_Lexus-RX_0001.JPG",
            "260921_Kaffi_Lexus-RX/PHOTO/JPG/260921_SR_Kaffi_Lexus-RX_0002.JPG",
        ])
    }

    @Test("two cards are numbered together in the order the shots were taken")
    func twoBodies() {
        let base = local(2026, 9, 21, 20, 0)
        var s = settings
        s.layout = FolderPreset.flat.layout
        s.folderPattern = ""
        let cards = [
            source("A", "A", [file("DCIM/100MSDCF/DSC00001.JPG", at: base), file("DCIM/100MSDCF/DSC00002.JPG", at: base.addingTimeInterval(20))]),
            source("B", "B", [file("DCIM/100CANON/IMG_0001.JPG", at: base.addingTimeInterval(10))]),
        ]
        let plan = Planner.plan(sources: cards, settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() })
        #expect(paths(plan) == [
            "260921_SR_Kaffi_Lexus-RX_0001.JPG",
            "260921_SR_Kaffi_Lexus-RX_0002.JPG",
            "260921_SR_Kaffi_Lexus-RX_0003.JPG",
        ])
        #expect(plan.toCopy.map(\.sourceID) == ["A", "B", "A"])

        // With the camera in the name, each camera counts on its own, as A-cam
        // and B-cam clips do on a set.
        s.namePattern = NamePreset.multicam.pattern
        let multicam = Planner.plan(sources: cards, settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() })
        #expect(paths(multicam) == [
            "260921_SR_Kaffi_Lexus-RX_A0001.JPG",
            "260921_SR_Kaffi_Lexus-RX_B0001.JPG",
            "260921_SR_Kaffi_Lexus-RX_A0002.JPG",
        ])
    }

    @Test("after midnight the shots keep the day the shoot started")
    func afterMidnight() {
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100MSDCF/DSC00001.JPG", at: local(2026, 9, 21, 23, 50)),
                file("DCIM/100MSDCF/DSC00002.JPG", at: local(2026, 9, 22, 1, 10)),
            ])],
            settings: settings, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(plan.shootFolders == ["260921_Kaffi_Lexus-RX"])
        #expect(plan.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus-RX_0001", "260921_SR_Kaffi_Lexus-RX_0002"])
    }

    @Test("a second card carries on from the numbers already on the drive")
    func carriesOn() {
        let existing = DestinationIndex(stems: [.photo: ["260921_SR_Kaffi_Lexus-RX_0041", "260921_SR_Kaffi_Lexus-RX_0042", "260921_SR_Other_0900"]])
        let plan = Planner.plan(
            sources: [source("A", "A", [file("DCIM/100MSDCF/DSC00100.JPG", at: local(2026, 9, 21, 22, 0))])],
            settings: settings, fixedDay: nil, drives: [drive], index: { _, _ in existing }
        )
        #expect(plan.toCopy.first?.baseName == "260921_SR_Kaffi_Lexus-RX_0043")
    }

    @Test("a card copied before is recognised on every drive, and only then")
    func alreadyCopied() {
        let t = local(2026, 9, 21, 22, 0)
        let known = file("DCIM/100MSDCF/DSC00001.JPG", at: t)
        let fresh = file("DCIM/100MSDCF/DSC00002.JPG", at: t.addingTimeInterval(5))
        let other = URL(fileURLWithPath: "/Volumes/SSD-B")
        let both = Planner.plan(
            sources: [source("A", "A", [known, fresh])],
            settings: settings, fixedDay: nil, drives: [drive, other],
            index: { _, _ in DestinationIndex(stems: [.photo: ["260921_SR_Kaffi_Lexus-RX_0001"]], fingerprints: [known.fingerprint]) }
        )
        #expect(both.alreadyCopied == 1)
        #expect(both.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus-RX_0002"])

        let oneDrive = Planner.plan(
            sources: [source("A", "A", [known, fresh])],
            settings: settings, fixedDay: nil, drives: [drive, other],
            index: { d, _ in d == other ? DestinationIndex() : DestinationIndex(fingerprints: [known.fingerprint]) }
        )
        #expect(oneDrive.alreadyCopied == 0)
        #expect(oneDrive.toCopy.count == 2)
    }

    @Test("Sony's XML keeps its suffix; proxies stay on the card unless asked")
    func sonyCompanions() {
        let t = local(2026, 9, 21, 21, 0)
        let files = [
            file("PRIVATE/M4ROOT/CLIP/C0007.MP4", at: t),
            file("PRIVATE/M4ROOT/CLIP/C0007M01.XML", at: t),
            file("PRIVATE/M4ROOT/SUB/C0007S03.MP4", at: t),
        ]
        let plan = Planner.plan(sources: [source("A", "A", files)], settings: settings, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() })
        #expect(paths(plan) == [
            "260921_Kaffi_Lexus-RX/VIDEO/260921_SR_Kaffi_Lexus-RX_0001.MP4",
            "260921_Kaffi_Lexus-RX/VIDEO/260921_SR_Kaffi_Lexus-RX_0001M01.XML",
        ])
        #expect(plan.leftOutCount == 1)

        var withProxies = settings
        withProxies.kindChoices[FileKind(role: .proxy, ext: "MP4").id] = true
        let full = Planner.plan(sources: [source("A", "A", files)], settings: withProxies, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() })
        #expect(paths(full).contains("260921_Kaffi_Lexus-RX/VIDEO/PROXY/260921_SR_Kaffi_Lexus-RX_0001S03.MP4"))

        var byDefault = settings
        byDefault.kindChoices = [:]
        let clipOnly = Planner.plan(sources: [source("A", "A", files)], settings: byDefault, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() })
        #expect(paths(clipOnly) == ["260921_Kaffi_Lexus-RX/VIDEO/260921_SR_Kaffi_Lexus-RX_0001.MP4"])
    }

    @Test("separate counters for photos and videos when asked")
    func separateCounters() {
        let t = local(2026, 9, 21, 21, 0)
        var s = settings
        s.sharedCounter = false
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100CANON/IMG_0001.JPG", at: t),
                file("DCIM/100CANON/MVI_0002.MP4", at: t.addingTimeInterval(1)),
                file("DCIM/100CANON/IMG_0003.JPG", at: t.addingTimeInterval(2)),
            ])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex(stems: [.video: ["260921_SR_Kaffi_Lexus-RX_0010"]]) }
        )
        #expect(plan.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus-RX_0001", "260921_SR_Kaffi_Lexus-RX_0011", "260921_SR_Kaffi_Lexus-RX_0002"])
    }

    @Test("a pattern without a number cannot silently merge two shots")
    func conflicts() {
        var s = settings
        s.namePattern = "{YYMMDD}_{CLIENT}"
        let t = local(2026, 9, 21, 21, 0)
        let plan = Planner.plan(
            sources: [source("A", "A", [file("DCIM/100CANON/IMG_0001.JPG", at: t), file("DCIM/100CANON/IMG_0002.JPG", at: t)])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(plan.conflicts.count == 1)
    }

    @Test("a fixed day wins over the camera's clock")
    func fixedDay() {
        let plan = Planner.plan(
            sources: [source("A", "A", [file("DCIM/100CANON/IMG_0001.JPG", at: local(2026, 1, 1, 12, 0))])],
            settings: settings, fixedDay: ShootDay(year: 2026, month: 9, day: 20), drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(plan.toCopy.first?.baseName == "260920_SR_Kaffi_Lexus-RX_0001")
    }

    // MARK: Kinds of file

    @Test("a Sony card without its XML: ARW, JPG, MP4 and MOV go, XML stays")
    func withoutXML() {
        let t = local(2026, 9, 21, 21, 0)
        var s = settings
        s.kindChoices[FileKind(role: .sidecar, ext: "XML").id] = false
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100MSDCF/DSC00001.ARW", at: t),
                file("DCIM/100MSDCF/DSC00001.JPG", at: t),
                file("PRIVATE/M4ROOT/CLIP/C0001.MP4", at: t.addingTimeInterval(10)),
                file("PRIVATE/M4ROOT/CLIP/C0001M01.XML", at: t.addingTimeInterval(10)),
                file("PRIVATE/M4ROOT/CLIP/C0002.MOV", at: t.addingTimeInterval(20)),
                file("PRIVATE/M4ROOT/CLIP/C0002M01.XML", at: t.addingTimeInterval(20)),
            ])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        let names = plan.toCopy.flatMap { $0.files.map(\.name) }
        #expect(names == [
            "260921_SR_Kaffi_Lexus-RX_0001.ARW",
            "260921_SR_Kaffi_Lexus-RX_0001.JPG",
            "260921_SR_Kaffi_Lexus-RX_0002.MP4",
            "260921_SR_Kaffi_Lexus-RX_0003.MOV",
        ])
        #expect(plan.leftOutCount == 2)
    }

    @Test("without the JPEG, the RAW keeps its number and its XMP follows it")
    func rawOnly() {
        let t = local(2026, 9, 21, 21, 0)
        var s = settings
        s.kindChoices[FileKind(role: .jpeg, ext: "JPG").id] = false
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100CANON/IMG_0001.CR3", at: t),
                file("DCIM/100CANON/IMG_0001.JPG", at: t),
                file("DCIM/100CANON/IMG_0001.XMP", at: t),
                file("DCIM/100CANON/IMG_0002.CR3", at: t.addingTimeInterval(1)),
            ])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(paths(plan) == [
            "260921_Kaffi_Lexus-RX/PHOTO/RAW/260921_SR_Kaffi_Lexus-RX_0001.CR3",
            "260921_Kaffi_Lexus-RX/PHOTO/RAW/260921_SR_Kaffi_Lexus-RX_0001.XMP",
            "260921_Kaffi_Lexus-RX/PHOTO/RAW/260921_SR_Kaffi_Lexus-RX_0002.CR3",
        ])
    }

    @Test("without the RAW, the XMP moves beside the JPEG")
    func jpegOnly() {
        let t = local(2026, 9, 21, 21, 0)
        var s = settings
        s.kindChoices[FileKind(role: .raw, ext: "CR3").id] = false
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100CANON/IMG_0001.CR3", at: t),
                file("DCIM/100CANON/IMG_0001.JPG", at: t),
                file("DCIM/100CANON/IMG_0001.XMP", at: t),
            ])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(paths(plan) == [
            "260921_Kaffi_Lexus-RX/PHOTO/JPG/260921_SR_Kaffi_Lexus-RX_0001.JPG",
            "260921_Kaffi_Lexus-RX/PHOTO/JPG/260921_SR_Kaffi_Lexus-RX_0001.XMP",
        ])
    }

    @Test("a shot with nothing ticked stays on the card and takes no number")
    func untickedShot() {
        let t = local(2026, 9, 21, 21, 0)
        var s = settings
        s.kindChoices[FileKind(role: .video, ext: "MP4").id] = false
        let plan = Planner.plan(
            sources: [source("A", "A", [
                file("DCIM/100CANON/IMG_0001.JPG", at: t),
                file("DCIM/100CANON/MVI_0002.MP4", at: t.addingTimeInterval(1)),
                file("DCIM/100CANON/MVI_0002.THM", at: t.addingTimeInterval(1)),
                file("DCIM/100CANON/IMG_0003.JPG", at: t.addingTimeInterval(2)),
            ])],
            settings: s, fixedDay: nil, drives: [drive], index: { _, _ in DestinationIndex() }
        )
        #expect(plan.toCopy.map(\.baseName) == ["260921_SR_Kaffi_Lexus-RX_0001", "260921_SR_Kaffi_Lexus-RX_0002"])
        #expect(plan.unticked == 1)
        #expect(plan.leftOutCount == 2)
    }

    @Test("unticking MP4 clips leaves Sony's MP4 proxies to their own choice")
    func proxyIsItsOwnKind() {
        let clip = file("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let proxy = file("PRIVATE/M4ROOT/SUB/C0001S03.MP4")
        #expect(clip.kind != proxy.kind)
        var s = IngestSettings()
        #expect(s.includes(clip.kind))
        #expect(!s.includes(proxy.kind))
        s.kindChoices[clip.kind.id] = false
        #expect(!s.includes(clip.kind))
        #expect(!s.includes(proxy.kind))
    }
}
