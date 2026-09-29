import Foundation
import Testing
@testable import Rushes

// One file, every drive, checked: the edges of the chunks, a card that hands
// back less than it holds, and a name refused on one drive of two.

@Suite("Copier", .serialized)
struct CopierTests {
    @Test("a file is copied whole at every chunk boundary", arguments: [
        0, 1, Copier.chunkSize - 1, Copier.chunkSize, Copier.chunkSize + 1, 2 * Copier.chunkSize,
    ])
    func chunkBoundaries(size: Int) throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let data = try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: size, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let a = try box.folder("A").appendingPathComponent("shoot/A_0001.ARW")
        let b = try box.folder("B").appendingPathComponent("shoot/A_0001.ARW")

        let hash = try Copier.copy(source, to: [a, b], size: Int64(size), modified: Date(), created: Date(), isCancelled: { false }) { _, _ in }

        #expect(try Data(contentsOf: a) == data)
        #expect(try Data(contentsOf: b) == data)
        #expect(try Copier.hash(of: a) == hash)
        #expect(try Copier.hash(of: b) == hash)
    }

    /// A reader that gives up says "end of file". What it did give would check
    /// out perfectly against itself, so the size the scan saw is the judge.
    @Test("a card that hands back fewer bytes than it listed is not believed")
    func shortReadFails() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 5_000, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let target = try box.folder("A").appendingPathComponent("shoot/A_0001.ARW")

        #expect(throws: Copier.Failure.self) {
            try Copier.copy(source, to: [target], size: 6_000, modified: Date(), created: Date(), isCancelled: { false }) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: Copier.partialURL(for: target).path))
    }

    /// The name appears on the second drive while the copies are read back:
    /// the first drive must not keep a finished file no record will list.
    @Test("a name refused on one drive is taken back from the other")
    func namedEverywhereOrNowhere() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 40_000, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let a = try box.folder("A").appendingPathComponent("shoot/A_0001.ARW")
        let b = try box.folder("B").appendingPathComponent("shoot/A_0001.ARW")
        let theirs = Data("a shot from another night".utf8)

        #expect(throws: Copier.Failure.self) {
            try Copier.copy(source, to: [a, b], modified: Date(), created: Date(), isCancelled: { false }) { _, verifying in
                if verifying, !FileManager.default.fileExists(atPath: b.path) { try? theirs.write(to: b) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: Copier.partialURL(for: a).path))
        #expect(try Data(contentsOf: b) == theirs)
    }

    @Test("progress counts every byte read back from every drive")
    func progressAddsUp() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let size = Copier.chunkSize * 2 + 123
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: size, date: Date())
        let source = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
        let a = try box.folder("A").appendingPathComponent("A_0001.ARW")
        let b = try box.folder("B").appendingPathComponent("A_0001.ARW")
        var read: Int64 = 0
        var verified: Int64 = 0

        _ = try Copier.copy(source, to: [a, b], modified: Date(), created: Date(), isCancelled: { false }) { bytes, verifying in
            if verifying { verified += bytes } else { read += bytes }
        }

        #expect(read == Int64(size))
        #expect(verified == Int64(size) * 2)
    }
}
