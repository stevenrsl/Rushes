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

    /// The volume a folder sits on.
    static func volume(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    /// Unmounts and ejects, off the main thread: a card that Spotlight or
    /// Photos is still reading can take seconds to answer.
    static func eject(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }
}
