import Foundation
import Testing
@testable import Rushes

// The copy sent once the drives are verified: read from a drive, never the
// card, held to the drives' rules on the other side (nothing replaced, named
// only once whole), and not sent twice.

@Suite("Upload", .serialized)
struct UploadTests {
    /// One verified file on a drive, as a backup leaves it, with its record.
    private func night(_ box: Sandbox) throws -> (drive: URL, report: BackupReport) {
        let drive = try box.folder("DRIVE")
        let shoot = "261015_Kaffi_Lexus"
        try box.write("\(shoot)/VIDEO/261015_SR_Kaffi_Lexus_0001_A.MP4", in: drive, size: 300_000, date: Date())
        let file = drive.appendingPathComponent("\(shoot)/VIDEO/261015_SR_Kaffi_Lexus_0001_A.MP4")
        let entry = Manifest.Entry(
            original: "PRIVATE/M4ROOT/CLIP/C0001.MP4", volume: "Untitled",
            path: "VIDEO/261015_SR_Kaffi_Lexus_0001_A.MP4", size: 300_000,
            xxh64: try Copier.hash(of: file), fingerprint: "C0001.MP4|300000|0", captured: Date()
        )
        var report = BackupReport()
        report.recorded = Date()
        report.entries = [shoot: [entry]]
        try History.write([entry], in: drive.appendingPathComponent(shoot), at: report.recorded)
        return (drive, report)
    }

    @Test("what was verified and the night's records are listed, read from the drive")
    func items() throws {
        let box = try Sandbox()
        let (drive, report) = try night(box)
        let items = Upload.items(of: report, on: [drive])

        #expect(items.map(\.relative) == [
            "261015_Kaffi_Lexus/VIDEO/261015_SR_Kaffi_Lexus_0001_A.MP4",
            "261015_Kaffi_Lexus/_RUSHES/\(History.stamp(report.recorded)).csv",
            "261015_Kaffi_Lexus/_RUSHES/\(History.stamp(report.recorded)).json",
        ])
        #expect(items.allSatisfy { $0.local.path.hasPrefix(drive.path) })
        #expect(items[0].size == 300_000)
        #expect(!items[0].xxh64.isEmpty)
    }

    @Test("a folder receives a copy read back, and a second send finds it there")
    func toFolder() throws {
        let box = try Sandbox()
        let (drive, report) = try night(box)
        let cloud = try box.folder("Cloud")
        var target = UploadTarget()
        target.kind = .folder
        target.folder = cloud.path
        let items = Upload.items(of: report, on: [drive])

        let first = Upload.run(items, to: target, password: nil, isCancelled: { false }) { _ in }
        #expect(first.succeeded)
        #expect(first.sent == items.count)
        let sent = cloud.appendingPathComponent(items[0].relative)
        #expect(try Data(contentsOf: sent) == Data(contentsOf: items[0].local))
        // No partial left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: sent.deletingLastPathComponent().path)
        #expect(!names.contains { $0.hasSuffix(".rushes-partial") })

        let second = Upload.run(items, to: target, password: nil, isCancelled: { false }) { _ in }
        #expect(second.succeeded)
        #expect(second.sent == 0)
        #expect(second.alreadyThere == items.count)
    }

    @Test("a different file under the same name is never replaced")
    func neverReplaced() throws {
        let box = try Sandbox()
        let (drive, report) = try night(box)
        let cloud = try box.folder("Cloud")
        let items = Upload.items(of: report, on: [drive])
        let taken = try box.write(items[0].relative, in: cloud, size: 12, date: Date())
        var target = UploadTarget()
        target.kind = .folder
        target.folder = cloud.path

        let result = Upload.run(items, to: target, password: nil, isCancelled: { false }) { _ in }
        #expect(result.failures.map(\.file) == [items[0].relative])
        #expect(try Data(contentsOf: cloud.appendingPathComponent(items[0].relative)) == taken)
    }

    @Test("a folder that is gone stops the send at once")
    func folderGone() throws {
        let box = try Sandbox()
        let (drive, report) = try night(box)
        var target = UploadTarget()
        target.kind = .folder
        target.folder = box.root.appendingPathComponent("Nowhere").path

        let result = Upload.run(Upload.items(of: report, on: [drive]), to: target, password: nil, isCancelled: { false }) { _ in }
        #expect(result.stopped != nil)
        #expect(result.sent == 0)
    }

    @Test("a server's address: login folder, root, port, a scheme pasted in, spaces")
    func serverURL() {
        var target = UploadTarget()
        target.kind = .ftps
        target.host = " ftp://nas.local/ "
        target.path = "rushes"
        #expect(target.serverHost == "nas.local")
        #expect(target.serverURL("261015_Kaffi/A 1.MP4")?.absoluteString == "ftp://nas.local/rushes/261015_Kaffi/A%201.MP4")

        target.path = "/srv/rushes/"
        target.port = 2121
        #expect(target.serverURL("x.MP4")?.absoluteString == "ftp://nas.local:2121/%2Fsrv/rushes/x.MP4")
        #expect(target.serverURL("", directory: true)?.absoluteString == "ftp://nas.local:2121/%2Fsrv/rushes/")
        #expect(target.keychainAccount == "@nas.local")
    }

    @Test("a password with quotes and backslashes is quoted for curl's config")
    func escaping() {
        #expect(Upload.escape(#"a"b\c"#) == #"a\"b\\c"#)
    }

    @Test("a target is ready only with what its kind needs")
    func readiness() {
        var target = UploadTarget()
        #expect(!target.isReady)
        target.kind = .ftp
        #expect(!target.isReady)
        target.host = "ftp.example.com"
        #expect(target.isReady)
        target.kind = .folder
        #expect(!target.isReady)
    }
}
