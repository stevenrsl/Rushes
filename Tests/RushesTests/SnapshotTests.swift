import AppKit
import SwiftUI
import Testing
@testable import Rushes

// Not a test of anything: renders pages to PNG for a person to look at, when
// RUSHES_SNAPSHOTS names a folder.
@Suite("Snapshots", .enabled(if: ProcessInfo.processInfo.environment["RUSHES_SNAPSHOTS"] != nil))
@MainActor
struct SnapshotTests {
    private func save(_ view: some View, _ name: String, dark: Bool) throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUSHES_SNAPSHOTS"]!)
        let renderer = ImageRenderer(content: view
            .frame(width: Page.width - Page.gutter * 2, alignment: .topLeading)
            .padding(.horizontal, Page.gutter)
            .frame(width: Page.width, height: 700, alignment: .topLeading)
            .pageGround()
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let rep = NSBitmapImageRep(cgImage: try #require(image))
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + (dark ? "-dark" : "") + ".png"))
    }

    @Test func auditPages() throws {
        let root = URL(fileURLWithPath: "/Volumes/SSD-Archive")
        let item = { (path: String) in Audit.Item(path: path, size: 24_000_000, xxh64: "72d6261af7224a64", original: "DCIM/100MSDCF/DSC01234.ARW", volume: "A7IV") }
        var damaged = Audit.Report(root: root, records: 14, checked: 4_812, bytes: 212_000_000_000)
        damaged.problems = [
            .init(item: item("260921_Kaffi_Lexus/PHOTO/RAW/260921_SR_Kaffi_Lexus_0042_A.ARW"), kind: .missing),
            .init(item: item("260921_Kaffi_Lexus/VIDEO/260921_SR_Kaffi_Lexus_0007_A.MP4"), kind: .changed("0badc0ffee000000")),
        ]
        var intact = damaged
        intact.problems = []
        for dark in [false, true] {
            try save(AuditView(scrolls: false).environment(AuditModel()), "audit-idle", dark: dark)
            try save(AuditView(scrolls: false).environment(AuditModel(showing: .running(root), progress: .init(done: 40, total: 100, filesDone: 1_900, filesTotal: 4_812, current: "260921_SR_Kaffi_Lexus_0042_A.ARW"))), "audit-running", dark: dark)
            try save(AuditView(scrolls: false).environment(AuditModel(showing: .finished(damaged))), "audit-damaged", dark: dark)
            try save(AuditView(scrolls: false).environment(AuditModel(showing: .finished(intact))), "audit-intact", dark: dark)
        }
    }

    @Test func stragglers() throws {
        let day = ShootDay(year: 2026, month: 11, day: 14)
        let target = ShootDay(year: 2026, month: 11, day: 23)
        var fresh = DaySpread.Straggler(day: day)
        fresh.photos = 2
        fresh.folder = "261114_Kaffi_Lexus"
        var saved = fresh
        saved.saved = 2
        saved.savedIn = "261114_Renault_Clio/PHOTO/RAW"
        let lines = VStack(alignment: .leading, spacing: 18) {
            ForEach(DayFiling.allCases, id: \.self) { filing in
                StragglerLine(straggler: fresh, target: target, filing: filing, choose: { _ in })
            }
            StragglerLine(straggler: saved, target: target, filing: .ownDay, choose: { _ in })
        }.padding(.top, 40)
        for dark in [false, true] { try save(lines, "stragglers", dark: dark) }
    }

    @Test func speedGraph() throws {
        var history = ThroughputHistory()
        // Ten minutes from a card at about 280 MB/s with a dip, then the read-back.
        for second in stride(from: 1.0, through: 900, by: 1) {
            let verifying = second > 600
            let base = verifying ? 420e6 : (second > 200 && second < 240 ? 60e6 : 280e6)
            let wobble = sin(second / 9) * 18e6
            history.add(at: second, seconds: 1, bytes: Int64(base + wobble), verifying: verifying)
        }
        for dark in [false, true] {
            try save(SpeedGraph(history: history, current: 415e6).padding(.top, 40), "speed-graph", dark: dark)
        }
    }

    @Test func threadMark() throws {
        for dark in [false, true] {
            let mark = ThreadMark()
                .stroke(Palette.accentLine.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 56, height: 56)
                .padding(40)
            try save(mark, "thread-mark", dark: dark)
        }
    }
}
