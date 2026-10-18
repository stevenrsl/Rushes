import AppKit
import Foundation

/// The drives and cards mounted on the Mac, kept current as they come and go.
@MainActor
final class VolumeWatcher {
    private(set) var volumes: [URL] = []
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Local volumes under /Volumes. The Mac's own disk is left out; a network
    /// share too, because reading its root can hang for seconds.
    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = mounted.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return url.path.hasPrefix("/Volumes/") && values?.volumeIsLocal != false && values?.volumeIsRootFileSystem != true
        }
        onChange?()
    }

    static func name(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func totalBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map(Int64.init)
    }

    /// The file system's short name, as `mount` prints it: `apfs`, `exfat`,
    /// `msdos` for FAT32, `smbfs`.
    nonisolated static func fileSystem(of url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The volume a folder sits on.
    nonisolated static func volume(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    /// A card's identity as its file system gives it: the volume serial of
    /// FAT and exFAT, written at each format. Two cards swapped in a reader
    /// mount at the same path under the same name; this tells them apart.
    nonisolated static func identity(of url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    struct FormatRefusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Erases a card that has been told "formatable", keeping its file system
    /// and its name, then ejects it. Steven asked on 2026-10-15 to be offered
    /// this from the done page rather than only in the camera.
    ///
    /// Everything is checked again here, at the last moment, because nothing
    /// can be undone afterwards: the volume is still the one that was verified
    /// (`identity`), it is mounted at that path, it is removable or ejectable
    /// media, and it is exFAT or FAT, what cameras write. Anything else is
    /// refused rather than guessed. `avoiding` holds the destinations' volumes.
    nonisolated static func format(_ url: URL, identity expected: String, avoiding: Set<String>) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard url.path != "/", !avoiding.contains(url.path) else {
                throw FormatRefusal(message: "c'est une destination de la sauvegarde.")
            }
            guard let now = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString, now == expected else {
                throw FormatRefusal(message: "la carte dans le lecteur n'est plus celle qui a été sauvegardée.")
            }
            let info = try diskutil(["info", "-plist", url.path])
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any],
                  let device = plist["DeviceIdentifier"] as? String, !device.isEmpty
            else { throw FormatRefusal(message: "le Mac ne dit pas quel disque elle est.") }
            guard (plist["MountPoint"] as? String) == url.path else {
                throw FormatRefusal(message: "elle n'est plus montée au même endroit.")
            }
            let removable = (plist["Ejectable"] as? Bool) == true || (plist["RemovableMedia"] as? Bool) == true
            guard removable else {
                throw FormatRefusal(message: "ce n'est pas une carte amovible.")
            }
            let fileSystem = (plist["FilesystemType"] as? String)?.lowercased() ?? ""
            let personality: String
            var name = (plist["VolumeName"] as? String) ?? url.lastPathComponent
            switch fileSystem {
            case "exfat":
                personality = "ExFAT"
            case "msdos":
                // FAT names are eleven capitals at most; diskutil picks FAT16
                // or FAT32 from the card's size, as the camera would.
                personality = "MS-DOS"
                name = name.uppercased()
            default:
                throw FormatRefusal(message: "Rushes ne formate que les cartes en exFAT ou en FAT, et celle-ci est en \(fileSystem.isEmpty ? "un format inconnu" : fileSystem).")
            }
            name = String(name.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " _-".unicodeScalars.contains($0)) }.map(Character.init).prefix(11))
            name = name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "UNTITLED" }
            _ = try diskutil(["eraseVolume", personality, name, device])
            // Back in the camera next: nothing else should open it now. The
            // whole disk, so a camera plugged by USB lets go of it too.
            let whole = (plist["ParentWholeDisk"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? device
            if (try? diskutil(["eject", whole])) == nil { _ = try? diskutil(["eject", device]) }
        }.value
    }

    /// Runs the Mac's diskutil and returns what it printed, or throws what it
    /// said when it fails.
    nonisolated private static func diskutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = String(decoding: err.isEmpty ? out : err, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? "diskutil \(process.terminationStatus)"
            throw FormatRefusal(message: said)
        }
        return String(decoding: out, as: UTF8.self)
    }

    enum Ejection: Sendable {
        /// Unmounted and ejected: the reader can be pulled.
        case ejected
        /// Unmounted, but the device would not eject its medium, which a
        /// camera plugged by USB often refuses: it can be unplugged all the same.
        case unmounted
    }

    /// Unmounts and ejects, off the main thread: a card that Spotlight or
    /// Photos is still reading can take seconds to answer.
    ///
    /// A card is ejected as the disk it is on, not as one volume: a camera
    /// plugged by USB shows its card as one volume of a disk of its own, and
    /// ejecting that volume alone left the body attached (reported
    /// 2026-10-16). The whole disk goes only when every volume on it may go;
    /// `keeping` holds the mount points that must stay (a card told "ne pas
    /// formater", a destination). A device that will not eject is still
    /// unmounted, and that is said rather than called a failure.
    nonisolated static func eject(_ url: URL, keeping: Set<String> = []) async throws -> Ejection {
        try await Task.detached(priority: .userInitiated) {
            let info = try? diskutil(["info", "-plist", url.path])
            let plist = info.flatMap { try? PropertyListSerialization.propertyList(from: Data($0.utf8), format: nil) as? [String: Any] }
            let device = plist?["DeviceIdentifier"] as? String
            let whole = plist?["ParentWholeDisk"] as? String
            // A card in the Mac's own SD slot says "internal" and "removable";
            // the Mac's own disks never get here, being no card.
            let removable = (plist?["RemovableMedia"] as? Bool) == true || (plist?["Ejectable"] as? Bool) == true
            if let whole, !whole.isEmpty, removable || (plist?["Internal"] as? Bool) != true {
                let others = mountPoints(on: whole).filter { $0 != url.path }
                if others.allSatisfy({ !keeping.contains($0) }), (try? diskutil(["eject", whole])) != nil {
                    return .ejected
                }
            }
            if !isMounted(url) { return .unmounted }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return .ejected
            } catch {
                // The medium would not eject; the volume may have gone anyway,
                // or go with a plain unmount.
                if !isMounted(url) { return .unmounted }
                if let device, (try? diskutil(["unmount", device])) != nil, !isMounted(url) { return .unmounted }
                throw error
            }
        }.value
    }

    /// Where each volume of a whole disk is mounted.
    nonisolated private static func mountPoints(on whole: String) -> [String] {
        guard let list = try? diskutil(["list", "-plist", whole]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(list.utf8), format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }
        var points: [String] = []
        for disk in disks {
            if let point = disk["MountPoint"] as? String { points.append(point) }
            let parts = ((disk["Partitions"] as? [[String: Any]]) ?? []) + ((disk["APFSVolumes"] as? [[String: Any]]) ?? [])
            for part in parts {
                if let point = part["MountPoint"] as? String { points.append(point) }
            }
        }
        return points
    }

    nonisolated private static func isMounted(_ url: URL) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return mounted.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
}
