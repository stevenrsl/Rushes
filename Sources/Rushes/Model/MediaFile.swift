import Foundation

/// What a file on a card is for. It decides which folder the file lands in and
/// whether it gets a number of its own or rides along with a sibling.
enum FileRole: String, Codable, Sendable, CaseIterable {
    case raw
    case jpeg
    case heif
    case video
    case audio
    /// XML, XMP, SRT: metadata that has to follow its file and keep its name.
    case sidecar
    /// LRV, LRF, Sony's SUB folder: low-resolution copies made by the camera.
    case proxy
    /// THM and Sony's THMBNL JPEGs: the camera's own previews, useless after the card.
    case thumbnail

    /// A primary file is a picture, a clip or a sound. Only primaries open a group;
    /// the other roles join the group of the primary they belong to, or are left.
    var isPrimary: Bool {
        switch self {
        case .raw, .jpeg, .heif, .video, .audio: true
        case .sidecar, .proxy, .thumbnail: false
        }
    }

    /// Which primary gives a group its folder for sidecars, and its date. A RAW
    /// wins over its JPEG because an XMP beside it is written for the RAW.
    var anchorRank: Int {
        switch self {
        case .raw: 0
        case .heif: 1
        case .jpeg: 2
        case .video: 3
        case .audio: 4
        case .sidecar, .proxy, .thumbnail: 9
        }
    }

    var isPhoto: Bool { self == .raw || self == .jpeg || self == .heif }
}

enum MediaCategory: String, Codable, Sendable {
    case photo, video, audio
}

/// What the person ticks to copy or not: a role and an extension. ARW and JPG
/// are two kinds of photo; Sony's SUB/C0001S03.MP4 is a proxy, not a clip, so
/// unticking MP4 leaves the proxies alone and the other way round.
struct FileKind: Hashable, Identifiable, Sendable {
    let role: FileRole
    /// Upper case, as cameras write it: ARW, JPG, MP4, XML.
    let ext: String

    var id: String { "\(role.rawValue).\(ext)" }

    /// Proxies, thumbnails and XML (Sony's clip metadata, which Steven leaves
    /// on the card) stay there until ticked; the rest goes.
    var includedByDefault: Bool {
        role != .proxy && role != .thumbnail && !(role == .sidecar && ext == "XML")
    }

    enum Family: Int, CaseIterable, Sendable {
        case photo, video, audio, sidecar, proxy, thumbnail

        var title: String {
            switch self {
            case .photo: "Photos"
            case .video: "Vidéos"
            case .audio: "Sons"
            case .sidecar: "Métadonnées"
            case .proxy: "Proxys"
            case .thumbnail: "Vignettes"
            }
        }
    }

    var family: Family {
        switch role {
        case .raw, .jpeg, .heif: .photo
        case .video: .video
        case .audio: .audio
        case .sidecar: .sidecar
        case .proxy: .proxy
        case .thumbnail: .thumbnail
        }
    }

    /// Where a kind sits in its family: RAW before JPEG before HEIF, then by name.
    var order: (Int, Int, String) { (family.rawValue, role.anchorRank, ext) }
}

enum MediaTypes {
    static let raw: Set<String> = [
        "arw", "srf", "sr2",            // Sony
        "cr2", "cr3", "crw",            // Canon
        "nef", "nrw",                   // Nikon
        "raf",                          // Fujifilm
        "orf", "ori",                   // Olympus, OM System
        "rw2", "rwl",                   // Panasonic, Leica
        "dng",                          // Leica, DJI, Pentax, Ricoh, phones
        "pef",                          // Pentax
        "srw",                          // Samsung
        "3fr", "fff",                   // Hasselblad
        "iiq",                          // Phase One
        "x3f",                          // Sigma
        "gpr",                          // GoPro
        "erf", "kdc", "dcr", "mos", "mrw", "mef",
    ]
    static let jpeg: Set<String> = ["jpg", "jpeg", "insp"]
    static let heif: Set<String> = ["heic", "heif", "hif"]
    static let video: Set<String> = [
        "mp4", "mov", "m4v", "mxf", "avi", "mts", "m2ts", "mpg",
        "braw", "r3d", "crm", "nev", "ari", "insv", "360", "mkv",
    ]
    static let audio: Set<String> = ["wav", "bwf", "mp3", "m4a", "aac", "aif", "aiff"]
    static let sidecar: Set<String> = ["xml", "xmp", "srt", "dat", "cif", "rmd"]
    static let proxy: Set<String> = ["lrv", "lrf"]
    static let thumbnail: Set<String> = ["thm"]

    /// Folders whose pictures are the camera's previews, not photographs.
    static let thumbnailFolders: Set<String> = ["THMBNL", "THUMBNAIL", "THUMBNAILS"]

    /// Folders never walked: the camera's databases, the Mac's and Windows'
    /// housekeeping, DJI's and Canon's caches, AVCHD's playlists.
    static let skippedFolders: Set<String> = [
        "MISC", "AVF_INFO", "DATABASE", "CANONMSC", "GENERAL", "CLIPINF", "PLAYLIST",
        "BACKUP", "LOST.DIR", "SYSTEM VOLUME INFORMATION", "$RECYCLE.BIN", "_RUSHES",
    ]

    /// The role of a file from its extension and the folders above it (from the
    /// card's root, any case), or nil when it is nothing Rushes copies.
    static func role(forExtension ext: String, folders: [String]) -> FileRole? {
        let e = ext.lowercased()
        let dirs = folders.map { $0.uppercased() }
        let parent = dirs.last ?? ""
        let grandparent = dirs.dropLast().last ?? ""
        if raw.contains(e) { return .raw }
        if jpeg.contains(e) { return thumbnailFolders.contains(parent) ? .thumbnail : .jpeg }
        if heif.contains(e) { return .heif }
        if video.contains(e) {
            // Sony keeps its proxies in M4ROOT/SUB (and XDROOT/Sub on the FX6, FX9).
            // Only there: a folder called SUB anywhere else holds real clips.
            let sonyRoot = grandparent == "M4ROOT" || grandparent == "XDROOT"
            return parent == "SUB" && sonyRoot ? .proxy : .video
        }
        if audio.contains(e) { return .audio }
        if sidecar.contains(e) { return .sidecar }
        if proxy.contains(e) { return .proxy }
        if thumbnail.contains(e) { return .thumbnail }
        return nil
    }
}

/// One file found on a card.
struct MediaFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// From the card's root, e.g. `DCIM/100MSDCF/DSC01234.ARW`. Written in the manifest.
    let relativePath: String
    let size: Int64
    let role: FileRole
    /// When the camera wrote the file. It does not change while the file sits
    /// on the card, which is what makes it part of the fingerprint.
    let modified: Date
    let created: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension }
    var kind: FileKind { FileKind(role: role, ext: ext.uppercased()) }

    /// What says "this exact file was already backed up", across ingests and
    /// Macs: the name the camera gave it, its size and when it was written.
    var fingerprint: String {
        // Whole seconds: FAT32 keeps two, exFAT a hundredth, and not every
        // driver rounds the rest the same way.
        "\(name.uppercased())|\(size)|\(Int(modified.timeIntervalSince1970.rounded(.down)))"
    }
}
