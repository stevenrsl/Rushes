import Darwin
import Foundation
import Testing
@testable import Rushes

// The drives of a shoot are not APFS. A Samsung T7 or a SanDisk Extreme comes
// formatted in exFAT, and exFAT has no `RENAME_EXCL`: a copy named through it
// alone was checked, then thrown away, all night long. These tests write to a
// real exFAT and a real FAT32 volume, made in /tmp and mounted away from the
// Finder, so the promise "nothing is ever replaced" is proved where it is kept.

/// A disk image of one file system, mounted outside `/Volumes`.
final class TestVolume {
    let mountPoint: URL
    private let image: URL

    /// `nil` when the Mac will not make or mount the image: the test says so
    /// and passes, rather than failing on a machine that cannot run it.
    init?(_ filesystem: String, megabytes: Int = 40) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-fs-\(UUID().uuidString)")
        image = base.appendingPathExtension("dmg")
        mountPoint = base
        guard TestVolume.run("/usr/bin/hdiutil", [
            "create", "-quiet", "-size", "\(megabytes)m", "-fs", filesystem,
            "-volname", "RUSHESTEST", "-layout", "NONE", image.path
        ]) else { return nil }
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard TestVolume.run("/usr/bin/hdiutil", [
            "attach", "-quiet", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image.path
        ]) else {
            try? FileManager.default.removeItem(at: image)
            return nil
        }
    }

    deinit {
        _ = TestVolume.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Whether the volume can name a file exclusively in one step.
    var supportsRenameExcl: Bool {
        let a = mountPoint.appendingPathComponent("rename-probe")
        let b = mountPoint.appendingPathComponent("rename-probe-2")
        guard FileManager.default.createFile(atPath: a.path, contents: Data("x".utf8)) else { return false }
        defer {
            unlink(a.path)
            unlink(b.path)
        }
        return renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) == 0
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

@Suite("File systems", .serialized)
struct FileSystemTests {
    /// The bug of 2026-09-22: every copy checked, then deleted, because the
    /// drive cannot name it. A card of one file is enough to catch it.
    @Test("a copy reaches an exFAT drive, the format they are sold in")
    func copyToExFAT() throws {
        guard let volume = TestVolume("ExFAT") else { return }
        #expect(!volume.supportsRenameExcl, "exFAT is the case this test is for")

        let box = try Sandbox()
        let card = try box.folder("CARD")
        let data = try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 3_000_000, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let target = volume.mountPoint.appendingPathComponent("260921_Kaffi_Lexus/PHOTO/RAW/260921_SR_Kaffi_Lexus_0001.ARW")

        let hash = try Copier.copy(source, to: [target], modified: Date(), created: Date(), isCancelled: { false }) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: target) == data)
        #expect(try Copier.hash(of: target) == hash)
        #expect(!FileManager.default.fileExists(atPath: Copier.partialURL(for: target).path))
    }

    /// The rule that holds the whole app: a name already taken is a conflict,
    /// never an overwrite. It has to hold on a drive without `RENAME_EXCL` too.
    @Test("a name already taken on exFAT is refused, and the file left alone")
    func neverReplacesOnExFAT() throws {
        guard let volume = TestVolume("ExFAT") else { return }

        let box = try Sandbox()
        let card = try box.folder("CARD")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 40_000, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let target = volume.mountPoint.appendingPathComponent("260921_SR_Kaffi_Lexus_0001.ARW")
        let theirs = Data("a shot from another night".utf8)
        try theirs.write(to: target)

        #expect(throws: Copier.Failure.self) {
            try Copier.copy(source, to: [target], modified: Date(), created: Date(), isCancelled: { false }) { _, _ in }
        }
        #expect(try Data(contentsOf: target) == theirs)
        #expect(!FileManager.default.fileExists(atPath: Copier.partialURL(for: target).path))
    }

    /// Nothing is left out silently: the card is formatted on the strength of
    /// what this list says, so a folder the Mac refused and a file of a kind
    /// nobody listed both have to come back by name.
    @Test("a folder the Mac will not open, and a file of an unknown kind, are named")
    func partialReadIsNamed() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let now = Date()
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000, date: now)
        try box.write("DCIM/100MSDCF/SETTINGS.OSV", in: card, size: 10, date: now)
        try box.write("DCIM/101MSDCF/DSC00002.ARW", in: card, size: 1_000, date: now)
        let locked = card.appendingPathComponent("DCIM/101MSDCF")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }

        let scan = try CardScanner.scan(card)

        #expect(scan.unreadableFolders == ["DCIM/101MSDCF"])
        #expect(!scan.isComplete)
        #expect(scan.unknown.map(\.name) == ["SETTINGS.OSV"])
        #expect(scan.unknown.first?.ext == "OSV")
        #expect(scan.photoCount == 1)
    }

    /// FAT32 answers that it has no `RENAME_EXCL` and then performs it anyway,
    /// so the fallback is chosen on the answer of the call, never on the name
    /// of the file system.
    @Test("a copy reaches a FAT32 drive")
    func copyToFAT32() throws {
        guard let volume = TestVolume("MS-DOS FAT32", megabytes: 64) else { return }

        let box = try Sandbox()
        let card = try box.folder("CARD")
        let data = try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 1_000_000, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let target = volume.mountPoint.appendingPathComponent("VIDEO/260921_SR_Kaffi_Lexus_0001.ARW")

        _ = try Copier.copy(source, to: [target], modified: Date(), created: Date(), isCancelled: { false }) { _, _ in }
        #expect(try Data(contentsOf: target) == data)
    }
}
