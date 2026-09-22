import Foundation
import Testing
@testable import Rushes

// The checksum is what says a backup is a backup. It is checked against the
// published vectors and against zstd, whose frames end with the low 32 bits of
// the XXH64 of their content: an implementation nobody here wrote.

@Suite("XXH64")
struct HashTests {
    @Test("the published vectors")
    func vectors() {
        #expect(XXHash64.hash(Data()) == 0xEF46_DB37_51D8_E999)
        #expect(XXHash64.hash(Data("a".utf8)) == 0xD24E_C4F1_A98C_6E5B)
        #expect(XXHash64.hash(Data("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
    }

    @Test("fed in pieces or at once, the same hash")
    func streaming() {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<1_000_003).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let whole = XXHash64.hash(data)
        for _ in 0..<20 {
            var hasher = XXHash64()
            var offset = 0
            while offset < data.count {
                let size = min(Int.random(in: 1...70_000), data.count - offset)
                hasher.update(data.subdata(in: offset..<offset + size))
                offset += size
            }
            #expect(hasher.digest() == whole)
        }
        var bytewise = XXHash64()
        for byte in data.prefix(100) { bytewise.update(Data([byte])) }
        #expect(bytewise.digest() == XXHash64.hash(data.prefix(100)))
    }

    @Test("agrees with zstd at every length around the stripes")
    func againstZstd() throws {
        let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let zstd else { return }
        let lengths = Array(0...70) + [255, 256, 1000, 4096, 65_537, 3_000_000]
        for length in lengths {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ length) })
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zstd)
            process.arguments = ["-q", "-c", "--check", "-1"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(data)
            try input.fileHandleForWriting.close()
            let frame = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let tail = frame.suffix(4)
            let checksum = tail.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            #expect(UInt32(truncatingIfNeeded: XXHash64.hash(data)) == checksum, "length \(length)")
        }
    }
}
