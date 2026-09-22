import Foundation
import Testing
@testable import Rushes

// The promise: a JPEG and its RAW leave the card sisters and arrive sisters.
// Each brand's card is laid out from its manual and from real cards.

func file(_ path: String, size: Int64 = 100, at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> MediaFile {
    let url = URL(fileURLWithPath: "/Volumes/CARD").appendingPathComponent(path)
    var folders = path.split(separator: "/").map(String.init)
    folders.removeLast()
    let role = MediaTypes.role(forExtension: url.pathExtension, folders: folders)!
    return MediaFile(url: url, relativePath: path, size: size, role: role, modified: date, created: date)
}

func names(_ groups: [MediaGroup]) -> [[String]] {
    groups.map { $0.files.map(\.name) }
}

@Suite("Grouping")
struct GroupingTests {
    @Test("Sony stills: the ARW and its JPEG are one shot")
    func sonyStills() {
        let (groups, orphans) = Grouping.group([
            file("DCIM/100MSDCF/DSC01234.JPG"),
            file("DCIM/100MSDCF/DSC01234.ARW"),
            file("DCIM/100MSDCF/DSC01235.JPG"),
        ])
        #expect(names(groups) == [["DSC01234.ARW", "DSC01234.JPG"], ["DSC01235.JPG"]])
        #expect(groups[0].anchor.role == .raw)
        #expect(orphans.isEmpty)
    }

    @Test("Sony XAVC: clip, XML, proxy and thumbnail across M4ROOT; the card's index stays behind")
    func sonyClips() {
        let (groups, orphans) = Grouping.group([
            file("PRIVATE/M4ROOT/CLIP/C0001.MP4"),
            file("PRIVATE/M4ROOT/CLIP/C0001M01.XML"),
            file("PRIVATE/M4ROOT/SUB/C0001S03.MP4"),
            file("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"),
            file("PRIVATE/M4ROOT/CLIP/C0002.MP4"),
            file("PRIVATE/M4ROOT/MEDIAPRO.XML"),
        ])
        #expect(groups.count == 2)
        let first = groups.first { $0.anchor.name == "C0001.MP4" }!
        #expect(Set(first.files.map(\.name)) == ["C0001.MP4", "C0001M01.XML", "C0001S03.MP4", "C0001T01.JPG"])
        #expect(first.files.first { $0.name == "C0001S03.MP4" }?.role == .proxy)
        #expect(first.files.first { $0.name == "C0001T01.JPG" }?.role == .thumbnail)
        #expect(first.category == .video)
        #expect(orphans.map(\.name) == ["MEDIAPRO.XML"])
    }

    @Test("a folder called SUB outside Sony's roots holds real clips")
    func subElsewhere() {
        #expect(file("DCIM/SUB/CLIP0001.MP4").role == .video)
    }

    @Test("Canon: the same number in two folders is two shots")
    func canonFolders() {
        let (groups, _) = Grouping.group([
            file("DCIM/100CANON/IMG_0001.CR3"),
            file("DCIM/100CANON/IMG_0001.JPG"),
            file("DCIM/101CANON/IMG_0001.CR3"),
            file("DCIM/100CANON/MVI_0002.MP4"),
        ])
        #expect(groups.count == 3)
        #expect(names(groups).contains(["IMG_0001.CR3", "IMG_0001.JPG"]))
    }

    @Test("GoPro: the LRV has another letter, the THM the same name")
    func gopro() {
        let (groups, orphans) = Grouping.group([
            file("DCIM/100GOPRO/GX010042.MP4"),
            file("DCIM/100GOPRO/GL010042.LRV"),
            file("DCIM/100GOPRO/GX010042.THM"),
            file("DCIM/100GOPRO/GX020042.MP4"),
            file("DCIM/100GOPRO/GL020042.LRV"),
        ])
        #expect(orphans.isEmpty)
        #expect(names(groups) == [["GX010042.MP4", "GL010042.LRV", "GX010042.THM"], ["GX020042.MP4", "GL020042.LRV"]])
    }

    @Test("DJI: photo, RAW, clip, subtitles and proxy by name")
    func dji() {
        let (groups, _) = Grouping.group([
            file("DCIM/DJI_001/DJI_0001.JPG"),
            file("DCIM/DJI_001/DJI_0001.DNG"),
            file("DCIM/DJI_001/DJI_0002.MP4"),
            file("DCIM/DJI_001/DJI_0002.SRT"),
            file("DCIM/DJI_001/DJI_0002.LRF"),
        ])
        #expect(names(groups) == [["DJI_0001.DNG", "DJI_0001.JPG"], ["DJI_0002.MP4", "DJI_0002.LRF", "DJI_0002.SRT"]])
    }

    @Test("an XMP named after the whole RAW file follows it")
    func doubleExtensionXMP() {
        let (groups, orphans) = Grouping.group([
            file("DCIM/100_FUJI/DSCF0001.RAF"),
            file("DCIM/100_FUJI/DSCF0001.RAF.xmp"),
        ])
        #expect(orphans.isEmpty)
        #expect(groups.first?.files.count == 2)
    }

    @Test("Nikon N-RAW: the NEV and its MP4 proxy share a name and a number")
    func nikonNRaw() {
        let (groups, _) = Grouping.group([
            file("DCIM/100NCZ_8/DSC_0001.NEV"),
            file("DCIM/100NCZ_8/DSC_0001.MP4"),
            file("DCIM/100NCZ_8/DSC_0001.DAT"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 3)
    }

    @Test("brands from their folders")
    func brands() {
        #expect(CameraBrand.detect(dcimFolders: ["100MSDCF"], topFolders: ["DCIM", "PRIVATE"], extensions: []) == .sony)
        #expect(CameraBrand.detect(dcimFolders: ["100EOSR5"], topFolders: ["DCIM"], extensions: []) == .canon)
        #expect(CameraBrand.detect(dcimFolders: ["100NCZ_8"], topFolders: ["DCIM"], extensions: []) == .nikon)
        #expect(CameraBrand.detect(dcimFolders: ["100_FUJI"], topFolders: ["DCIM"], extensions: []) == .fujifilm)
        #expect(CameraBrand.detect(dcimFolders: ["100GOPRO"], topFolders: ["DCIM"], extensions: []) == .gopro)
        #expect(CameraBrand.detect(dcimFolders: ["DJI_001"], topFolders: ["DCIM"], extensions: []) == .dji)
        #expect(CameraBrand.detect(dcimFolders: [], topFolders: ["PRIVATE"], extensions: []) == .sony)
        #expect(CameraBrand.detect(dcimFolders: [], topFolders: ["CONTENTS"], extensions: []) == .canon)
    }
}
