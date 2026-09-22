import Foundation

/// The brand is shown on the card, and says which layout the scanner met. The
/// scanner itself treats every card the same way: it walks the whole card,
/// keeps what it recognises by extension and lets `Grouping` pair the files, so
/// a camera nobody listed here still works.
enum CameraBrand: String, Sendable, CaseIterable {
    case sony = "Sony"
    case canon = "Canon"
    case nikon = "Nikon"
    case fujifilm = "Fujifilm"
    case panasonic = "Panasonic"
    case om = "OM System"
    case leica = "Leica"
    case pentax = "Pentax"
    case hasselblad = "Hasselblad"
    case sigma = "Sigma"
    case gopro = "GoPro"
    case dji = "DJI"
    case insta360 = "Insta360"
    case blackmagic = "Blackmagic"
    case apple = "Apple"
    case unknown = "Carte"

    /// From the folders the camera made. DCF folders are three digits and five
    /// characters, and the five are the maker's: 100MSDCF, 100CANON, 100EOSR5,
    /// 100NCZ_8, 100_FUJI, 100_PANA, 100OLYMP, 100GOPRO, 100MEDIA.
    static func detect(dcimFolders: [String], topFolders: [String], extensions: Set<String>) -> CameraBrand {
        let top = Set(topFolders.map { $0.uppercased() })
        for folder in dcimFolders.map({ $0.uppercased() }) {
            let tail = folder.count > 3 ? String(folder.dropFirst(3)) : folder
            switch true {
            case tail.hasSuffix("MSDCF"): return .sony
            case tail.hasPrefix("CANON"), tail.hasPrefix("EOS"): return .canon
            case tail.hasPrefix("NIKON"), tail.hasPrefix("NCZ"), tail.hasPrefix("NZ"), tail.hasPrefix("ND"): return .nikon
            case tail.hasPrefix("_FUJI"): return .fujifilm
            case tail.hasPrefix("_PANA"): return .panasonic
            case tail.hasPrefix("OLYMP"), tail.hasPrefix("OMSYS"): return .om
            case tail.hasPrefix("LEICA"): return .leica
            case tail.hasPrefix("_PENTX"), tail.hasPrefix("PENTX"), tail.hasPrefix("RICOH"): return .pentax
            case tail.hasPrefix("HBLAD"), tail.hasPrefix("HASBL"): return .hasselblad
            case tail.hasPrefix("SIGMA"): return .sigma
            case tail.hasPrefix("GOPRO"): return .gopro
            case tail.hasPrefix("MEDIA"), folder.hasPrefix("DJI_"): return .dji
            case tail.hasPrefix("APPLE"): return .apple
            case folder.hasPrefix("CAMERA"): return .insta360
            default: continue
            }
        }
        if top.contains("PRIVATE") || top.contains("XDROOT") { return .sony }
        if top.contains("CONTENTS") { return .canon }
        if extensions.contains("braw") { return .blackmagic }
        return .unknown
    }
}

/// Everything found on one card.
struct CardScan: Sendable {
    let root: URL
    let groups: [MediaGroup]
    /// Companions with no primary beside them: never copied, always counted.
    let orphans: [MediaFile]
    /// Files the scanner does not know: the camera's databases and settings.
    let unknownCount: Int
    let brand: CameraBrand
    /// The body the card came from, from its photos' EXIF or Sony's clip XML;
    /// the brand alone when neither says more.
    var camera: CameraIdentity?

    var cameraName: String { camera?.name ?? brand.rawValue }

    var photoCount: Int { groups.filter { $0.category == .photo }.count }
    var videoCount: Int { groups.filter { $0.category == .video }.count }
    var audioCount: Int { groups.filter { $0.category == .audio }.count }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var firstDate: Date? { groups.map(\.captureDate).min() }
    var lastDate: Date? { groups.map(\.captureDate).max() }
}

enum CardScanner {
    /// A mounted volume is a camera card when it has what cameras write at the
    /// top: DCIM for stills and most video, PRIVATE for Sony and AVCHD, XDROOT
    /// for Sony's cinema line, CONTENTS for Canon's.
    static func looksLikeCard(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let upper = Set(names.map { $0.uppercased() })
        if !upper.isDisjoint(with: ["DCIM", "XDROOT", "CONTENTS"]) { return true }
        if upper.contains("PRIVATE") {
            let privateNames = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(names.first { $0.uppercased() == "PRIVATE" }!).path)) ?? []
            return privateNames.contains { ["M4ROOT", "AVCHD", "XDROOT"].contains($0.uppercased()) }
        }
        // A Blackmagic or a recorder writes its clips at the top.
        return names.contains { ["braw", "r3d"].contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Walks the card. Hidden files, AppleDouble files and the camera's own
    /// housekeeping folders are skipped; everything else is classified.
    static func scan(_ root: URL) throws -> CardScan {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var files: [MediaFile] = []
        var unknown = 0
        var extensions: Set<String> = []

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(rootDepth))
            if values?.isDirectory == true {
                if MediaTypes.skippedFolders.contains(url.lastPathComponent.uppercased()) {
                    walker.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let folders = Array(components.dropLast())
            guard let role = MediaTypes.role(forExtension: url.pathExtension, folders: folders) else {
                unknown += 1
                continue
            }
            extensions.insert(url.pathExtension.lowercased())
            let modified = values?.contentModificationDate ?? .distantPast
            files.append(MediaFile(
                url: url,
                relativePath: components.joined(separator: "/"),
                size: Int64(values?.fileSize ?? 0),
                role: role,
                modified: modified,
                created: values?.creationDate ?? modified
            ))
        }

        let (groups, orphans) = Grouping.group(files)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let dcimName = names.first { $0.uppercased() == "DCIM" }
        let dcim = dcimName.flatMap { try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent($0).path) } ?? []
        return CardScan(
            root: root,
            groups: groups,
            orphans: orphans,
            unknownCount: unknown,
            brand: CameraBrand.detect(dcimFolders: dcim, topFolders: names, extensions: extensions),
            camera: nil
        )
    }
}
