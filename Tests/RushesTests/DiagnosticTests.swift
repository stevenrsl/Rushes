import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Rushes

// A tester's card, described in a file Steven reads to add a camera he does
// not own. It has to say what the backup would do, and nothing personal.

@Suite("Card diagnostic")
struct DiagnosticTests {
    /// A real JPEG with the EXIF a camera writes, serial included.
    private func photo(at date: Date, model: String, serial: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: model],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date),
                                             kCGImagePropertyExifBodySerialNumber: serial],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("a card is described as the backup would see it, and read back the same")
    func describeAndReadBack() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let t = local(2026, 9, 21, 23, 30)
        let jpeg = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try box.write("DCIM/100MSDCF/DSC00001.ARW", in: card, size: 2_000, date: t)
        try FileManager.default.createDirectory(at: jpeg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photo(at: t, model: "ILCE-7M4", serial: "5551234").write(to: jpeg)
        try box.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", in: card, size: 3_000, date: t)
        try box.write("PRIVATE/M4ROOT/CLIP/C0001M01.XML", in: card, size: 300, date: t)
        try box.write("PRIVATE/M4ROOT/MEDIAPRO.XML", in: card, size: 100, date: t)
        try box.write("PRIVATE/SONY/SONYCARD.IND", in: card, size: 10, date: t)
        try box.write("BACKUP/IMG_0042.JPG", in: card, size: 500, date: t)
        try box.write("MISC/VERSION.TXT", in: card, size: 10, date: t)
        try box.write(".Spotlight-V100/store.db", in: card, size: 10, date: t)
        try box.write("System Volume Information/IndexerVolumeGuid", in: card, size: 10, date: t)

        let made = try CardDiagnostic.make(card, settings: IngestSettings(), now: t)
        let data = try made.encoded()
        let read = try CardDiagnostic.read(data)
        #expect(read == made)

        let fate = Dictionary(uniqueKeysWithValues: read.entries.map { ($0.path, $0.fate) })
        #expect(fate["DCIM/100MSDCF/DSC00001.ARW"] == .shot)
        #expect(fate["DCIM/100MSDCF/DSC00001.JPG"] == .shot)
        #expect(fate["PRIVATE/M4ROOT/CLIP/C0001M01.XML"] == .shot)
        #expect(fate["PRIVATE/M4ROOT/MEDIAPRO.XML"] == .orphan)
        #expect(fate["PRIVATE/SONY/SONYCARD.IND"] == .unknown)
        #expect(fate["BACKUP"] == .setAsideFolder)
        #expect(fate["BACKUP/IMG_0042.JPG"] == .setAside)
        #expect(fate["MISC/VERSION.TXT"] == .housekeeping)
        #expect(fate[".Spotlight-V100"] == .macFile)
        #expect(fate[".Spotlight-V100/store.db"] == nil)
        #expect(fate["System Volume Information"] == .notWalked)
        #expect(fate["System Volume Information/IndexerVolumeGuid"] == nil)

        let arw = try #require(read.entries.first { $0.path == "DCIM/100MSDCF/DSC00001.ARW" })
        #expect(arw.role == "raw")
        #expect(arw.anchor == true)
        #expect(arw.size == 2_000)
        #expect(read.entries.first { $0.path == "BACKUP/IMG_0042.JPG" }?.hiddenBy == "BACKUP")

        #expect(read.brand == "Sony")
        #expect(read.camera == CardDiagnostic.Camera(name: "Sony ILCE-7M4", hasSerial: true))
        #expect(read.summary.photos == 1)
        #expect(read.summary.videos == 1)
        #expect(read.summary.exifModels == ["Sony ILCE-7M4": 1])
        #expect(read.groups.first { $0.anchor.hasSuffix("DSC00001.ARW") }?.exifModel == "Sony ILCE-7M4")
        let xml = try #require(read.kinds.first { $0.id == "sidecar.XML" })
        #expect(xml.files == 2)
        #expect(xml.copiedByDefault == false)
        #expect(xml.copiedHere == false)
        #expect(read.suggestedFileName == "diagnostic-sony-260921-2330.json")
    }

    @Test("neither the body's serial nor where the card is mounted is written")
    func nothingPersonal() throws {
        let box = try Sandbox()
        let card = try box.folder("Mariage-Dupont")
        let t = local(2026, 9, 21, 23, 30)
        let jpeg = card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG")
        try FileManager.default.createDirectory(at: jpeg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photo(at: t, model: "ILCE-7M4", serial: "5551234").write(to: jpeg)

        let text = String(decoding: try CardDiagnostic.make(card, settings: IngestSettings(), now: t).encoded(), as: UTF8.self)
        #expect(!text.contains("5551234"))
        #expect(!text.contains("Mariage"))
        #expect(!text.contains(box.root.lastPathComponent))
        #expect(text.contains("DSC00001.JPG"))
    }

    @Test("a picture the camera hid is named as set aside")
    func hiddenFile() throws {
        let box = try Sandbox()
        let card = try box.folder("CARD")
        let t = local(2026, 9, 21, 22, 0)
        try box.write("DCIM/100MSDCF/DSC00002.ARW", in: card, size: 1_000, date: t)
        #expect(chflags(card.appendingPathComponent("DCIM/100MSDCF/DSC00002.ARW").path, UInt32(UF_HIDDEN)) == 0)

        let read = try CardDiagnostic.read(CardDiagnostic.make(card, settings: IngestSettings(), now: t).encoded())
        let entry = try #require(read.entries.first { $0.path == "DCIM/100MSDCF/DSC00002.ARW" })
        #expect(entry.fate == .setAside)
        #expect(entry.hidden)
        #expect(entry.hiddenBy == "")
    }
}
