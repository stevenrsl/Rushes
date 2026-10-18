import Foundation
import Testing
@testable import Rushes

// Made again at every keystroke that changes the plan, off the main thread.
// 520 ms on 2026-10-16 before the file's name, kind and fingerprint were kept
// and the name's pieces stopped building a character set each; 150 ms after.
// RUSHES_BENCH=1 swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/rushes-release --filter PlanBench
@Suite("PlanBench", .enabled(if: ProcessInfo.processInfo.environment["RUSHES_BENCH"] != nil))
struct PlanBench {
    @Test("a plan of 10 000 shots, and what the page reads of it")
    func tenThousand() {
        let base = local(2026, 9, 21, 20, 0)
        var files: [MediaFile] = []
        for i in 0..<10_000 {
            let folder = 100 + i / 999
            let stem = String(format: "DSC%05d", i % 9999)
            let t = base.addingTimeInterval(Double(i))
            files.append(file("DCIM/\(folder)MSDCF/\(stem).JPG", at: t))
            if i % 2 == 0 { files.append(file("DCIM/\(folder)MSDCF/\(stem).ARW", at: t)) }
        }
        let groups = Grouping.group(files).groups
        let source = PlanSource(id: "A", volumeName: "A", cameraLabel: "A", groups: groups)
        var settings = IngestSettings()
        settings.client = "Kaffi"; settings.project = "Lexus"
        func time(_ label: String, _ body: () -> Void) {
            let start = Date()
            body()
            print("BENCH \(label): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        var plan = IngestPlan()
        time("plan") {
            plan = Planner.plan(sources: [source], settings: settings, fixedDay: nil, drives: [URL(fileURLWithPath: "/tmp/nowhere")],
                                index: { _, _ in DestinationIndex() }, journal: { _ in DriveJournal() })
        }
        time("preview rows") { _ = PreviewRows(plan: plan, sources: [source], settings: settings) }
    }
}
