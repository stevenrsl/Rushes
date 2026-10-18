import Foundation
import Testing
@testable import Rushes

// Version 0.6: the photos on one drive and the videos on another, or in two
// folders of one. Every rule that said "every drive" now says "every drive
// that receives this kind of shot".

@Suite("Routing", .serialized)
struct RoutingTests {
    private struct Night {
        let card: URL, photos: URL, videos: URL
        var settings: IngestSettings
        let plan: IngestPlan
        let report: BackupReport
    }

    private func source(_ card: URL) throws -> PlanSource {
        PlanSource(id: card.path, volumeName: "CARD", cameraLabel: "A", groups: try CardScanner.scan(card).groups)
    }

    private func night(_ box: Sandbox, receives: (photos: Set<MediaCategory>, videos: Set<MediaCategory>) = ([.photo], [.video, .audio])) throws -> Night {
        let card = try box.folder("CARD")
        let photos = try box.folder("PHOTOS")
        let videos = try box.folder("VIDEOS")
        let t = local(2026, 10, 16, 21, 0)
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 20_000, date: t)
        try box.write("DCIM/100MSDCF/DSC00001.JPG", in: card, size: 5_000, date: t)
        try box.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", in: card, size: 30_000, date: t.addingTimeInterval(60))
        var settings = IngestSettings()
        settings.initials = "SR"
        settings.client = "Kaffi"
        settings.project = "Lexus"
        settings.namePattern = NamePreset.standard.pattern
        settings.destinations = [photos.path, videos.path]
        settings.setReceives(photos.path, receives.photos)
        settings.setReceives(videos.path, receives.videos)
        let plan = Planner.plan(sources: [try source(card)], settings: settings, fixedDay: nil, drives: [photos, videos])
        let report = Backup.run(plan, drives: [photos, videos], isCancelled: { false }) { _ in }
        return Night(card: card, photos: photos, videos: videos, settings: settings, plan: plan, report: report)
    }

    private func exists(_ drive: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: drive.appendingPathComponent(path).path)
    }

    @Test("each kind lands on its own drive, and each drive's records list only what it holds")
    func split() throws {
        let box = try Sandbox()
        let n = try night(box)
        #expect(n.report.succeeded, "\(n.report.failures)")
        let raw = "261016_Kaffi_Lexus/PHOTO/RAW/261016_SR_Kaffi_Lexus_0001.ARW"
        let clip = "261016_Kaffi_Lexus/VIDEO/261016_SR_Kaffi_Lexus_0001.MP4"
        #expect(exists(n.photos, raw) && !exists(n.videos, raw))
        #expect(exists(n.videos, clip) && !exists(n.photos, clip))

        let onPhotos = History.entries(in: n.photos.appendingPathComponent("261016_Kaffi_Lexus")).map(\.path)
        let onVideos = History.entries(in: n.videos.appendingPathComponent("261016_Kaffi_Lexus")).map(\.path)
        #expect(Set(onPhotos) == ["PHOTO/RAW/261016_SR_Kaffi_Lexus_0001.ARW", "PHOTO/JPG/261016_SR_Kaffi_Lexus_0001.JPG"])
        #expect(onVideos == ["VIDEO/261016_SR_Kaffi_Lexus_0001.MP4"])
        #expect(DriveJournal.load(n.videos).saved.count == 1)

        let scan = try CardScanner.scan(n.card)
        let verdict = Verdicts.of(cardID: n.card.path, cardName: "CARD", scan: scan, plan: n.plan, report: n.report)
        #expect(verdict.level == .safe)
        #expect(n.report.bytesMoved == 25_000 * 2 + 30_000 * 2)
    }

    @Test("a shot is saved when every drive that receives it holds it")
    func skippedOnItsOwnDrives() throws {
        let box = try Sandbox()
        let n = try night(box)
        let again = Planner.plan(sources: [try source(n.card)], settings: n.settings, fixedDay: nil, drives: [n.photos, n.videos])
        #expect(again.toCopy.isEmpty)
        #expect(again.alreadyCopied == 2)

        // Ticked for the video drive too, the photos are now missing there.
        var both = n.settings
        both.setReceives(n.videos.path, Set(MediaCategory.allCases))
        let more = Planner.plan(sources: [try source(n.card)], settings: both, fixedDay: nil, drives: [n.photos, n.videos])
        #expect(more.toCopy.map(\.group.category) == [.photo])
    }

    @Test("a kind no drive receives holds the button and the card")
    func unrouted() throws {
        let box = try Sandbox()
        let n = try night(box, receives: ([.photo], [.photo]))
        #expect(n.plan.unrouted == [.video])
        let drives = [n.photos, n.videos].map {
            Readiness.Drive(name: $0.lastPathComponent, isOnline: true, available: 1 << 40, fileSystem: "apfs", volume: $0.path, path: $0.path)
        }
        let blockers = Readiness(cards: 1, scanning: false, planning: false, ready: 1, cardWithoutLetter: false,
                                 drives: drives, settings: n.settings, plan: n.plan).blockers
        #expect(blockers.contains("Aucun disque ne reçoit les vidéos : choisis-en un dans Destinations."))
        let verdict = Verdicts.of(cardID: n.card.path, cardName: "CARD", scan: try CardScanner.scan(n.card), plan: n.plan, report: n.report)
        #expect(verdict.level == .hold)
    }

    @Test("two folders of one disk are two places when they share no kind")
    func sameDiskSplit() throws {
        let box = try Sandbox()
        let n = try night(box)
        let one = { (url: URL) in
            Readiness.Drive(name: url.lastPathComponent, isOnline: true, available: 1 << 40, fileSystem: "apfs", volume: "/Volumes/T7", path: url.path)
        }
        func gate(_ settings: IngestSettings) -> [String] {
            Readiness(cards: 1, scanning: false, planning: false, ready: 1, cardWithoutLetter: false,
                      drives: [one(n.photos), one(n.videos)], settings: settings, plan: n.plan).blockers
        }
        #expect(!gate(n.settings).contains { $0.contains("sur le même disque") })
        var shared = n.settings
        shared.setReceives(n.videos.path, [.video, .photo])
        #expect(gate(shared).contains { $0.contains("sur le même disque") })
    }

    @Test("the send takes each half from its drive, and both drives' records")
    func sendBothHalves() throws {
        let box = try Sandbox()
        let n = try night(box)
        let items = Upload.items(of: n.report, on: [n.photos, n.videos])
        let files = items.filter { !$0.relative.contains(History.folderName) }
        #expect(files.count == 3)
        #expect(files.first { $0.relative.hasSuffix(".MP4") }?.local.path.hasPrefix(n.videos.path) == true)
        let records = items.filter { $0.relative.contains(History.folderName) }.map(\.relative)
        #expect(Set(records).count == records.count)
        #expect(records.contains { $0.contains("-VIDEOS.json") })
    }

    @Test("emptying the card checks each file on its own drives only")
    func cleanupOwnDrives() throws {
        let box = try Sandbox()
        let n = try night(box)
        let items = CardCleanup.items(cardID: n.card.path, plan: n.plan, report: n.report, drives: [n.photos, n.videos])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.copies.count == 1 && CardCleanup.refusal($0) == nil })
    }

    @Test("what each destination receives is kept, everything stored as nothing")
    func receivesSetting() {
        var s = IngestSettings()
        s.destinations = ["/A", "/B"]
        #expect(!s.routes)
        s.setReceives("/A", [.video])
        #expect(s.receives("/A") == [.video])
        #expect(s.routes)
        s.setReceives("/A", [])
        #expect(s.receives("/A") == [.video])
        s.setReceives("/A", Set(MediaCategory.allCases))
        #expect(s.destinationKinds.isEmpty)
        s.setReceives("/B", [.photo, .audio])
        let back = try! JSONDecoder().decode(IngestSettings.self, from: try! JSONEncoder().encode(s))
        #expect(back.receives("/B") == [.photo, .audio])
    }
}
