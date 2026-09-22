import Foundation

/// A DCF object, in the words of the camera file system standard (JEITA CP-3461):
/// the files that share a folder and a base name are one shot. DSC01234.JPG and
/// DSC01234.ARW, C0001.MP4 and its C0001M01.XML, DJI_0001.MP4 and its .SRT.
/// A group gets one number, so the JPEG and its RAW stay sisters once renamed.
struct MediaGroup: Identifiable, Hashable, Sendable {
    /// Folder and base name once each brand's quirks are folded away.
    let key: String
    /// Primaries first, the anchor at the head, then sidecars, proxies, thumbnails.
    let files: [MediaFile]
    /// The camera's clock when the shot was taken. The file system's date until
    /// `CaptureDates` has read the EXIF.
    var captureDate: Date
    var cameraModel: String?

    var id: String { key }

    init(key: String, files: [MediaFile]) {
        self.key = key
        self.files = files.sorted { a, b in
            if a.role.anchorRank != b.role.anchorRank { return a.role.anchorRank < b.role.anchorRank }
            return a.name < b.name
        }
        let anchor = self.files[0]
        captureDate = min(anchor.created, anchor.modified)
    }

    /// The primary that names the group and gives its sidecars a folder.
    var anchor: MediaFile { files[0] }
    var primaries: [MediaFile] { files.filter(\.role.isPrimary) }

    var category: MediaCategory {
        if files.contains(where: \.role.isPhoto) { return .photo }
        if files.contains(where: { $0.role == .video }) { return .video }
        return .audio
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The picture whose EXIF gives the group its date: a JPEG reads fastest.
    var exifSource: MediaFile? {
        files.first { $0.role == .jpeg } ?? files.first { $0.role == .heif } ?? files.first { $0.role == .raw }
    }
}

enum Grouping {
    /// The group a file belongs to, from its path on the card.
    ///
    /// Most brands need nothing: same folder, same base name. Two need help.
    /// Sony's XAVC cards spread one clip over three folders with a suffix each
    /// (CLIP/C0001.MP4, CLIP/C0001M01.XML, SUB/C0001S03.MP4, THMBNL/C0001T01.JPG).
    /// GoPro changes the second letter for the proxy (GX010001.MP4, GL010001.LRV).
    static func key(forRelativePath relativePath: String) -> String {
        var folders = relativePath.split(separator: "/").map { String($0).uppercased() }
        let fileName = folders.removeLast()
        var stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension.lowercased()

        // An XMP some software names IMG_0001.CR3.xmp belongs to IMG_0001.
        if MediaTypes.sidecar.contains(ext) {
            let inner = (stem as NSString).pathExtension.lowercased()
            if !inner.isEmpty, MediaTypes.role(forExtension: inner, folders: folders)?.isPrimary == true {
                stem = (stem as NSString).deletingPathExtension
            }
        }

        if folders.count >= 2 {
            let parent = folders[folders.count - 1]
            let root = folders[folders.count - 2]
            if root == "M4ROOT" || root == "XDROOT", ["CLIP", "SUB", "THMBNL"].contains(parent) {
                folders[folders.count - 1] = "CLIP"
                if let match = stem.wholeMatch(of: #/(.+)[MST]\d\d/#), parent != "CLIP" || ext == "xml" {
                    stem = String(match.1)
                }
            }
        }

        if let parent = folders.last, parent.wholeMatch(of: #/\d{3}GOPRO/#) != nil,
           let match = stem.wholeMatch(of: #/G[A-Z](\d{6})/#) {
            stem = "G*" + match.1
        }

        return (folders + [stem]).joined(separator: "/")
    }

    /// Groups the files of one card. Sidecars, proxies and thumbnails whose
    /// primary is not there (Sony's MEDIAPRO.XML, a stray THM) come back apart.
    static func group(_ files: [MediaFile]) -> (groups: [MediaGroup], orphans: [MediaFile]) {
        var byKey: [String: [MediaFile]] = [:]
        var companions: [(String, MediaFile)] = []
        for file in files {
            let key = key(forRelativePath: file.relativePath)
            if file.role.isPrimary {
                byKey[key, default: []].append(file)
            } else {
                companions.append((key, file))
            }
        }
        var orphans: [MediaFile] = []
        for (key, file) in companions {
            if byKey[key] != nil {
                byKey[key]!.append(file)
            } else {
                orphans.append(file)
            }
        }
        let groups = byKey.map { MediaGroup(key: $0.key, files: $0.value) }.sorted { $0.key < $1.key }
        return (groups, orphans.sorted { $0.relativePath < $1.relativePath })
    }
}
