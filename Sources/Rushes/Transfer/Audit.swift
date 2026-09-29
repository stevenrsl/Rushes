import Foundation

/// Reads a drive back, months later, against what its records say it holds.
///
/// Every backup leaves `_RUSHES/<stamp>.json` in the shoot's folder: each
/// file's path, size and xxh64. A drive that has travelled, sat in a drawer or
/// been copied to an archive can be asked whether that is still true, before
/// the other copy is wiped. Every listed file is read again around the Mac's
/// cache and hashed; what is missing, has another size or reads differently is
/// named. Nothing on the drive is written, moved or repaired: a check that
/// changes what it checks proves nothing.
///
/// The records are found by walking the chosen folder, not through the drive's
/// journal: a shoot moved to an archive keeps its manifests and leaves the
/// journal behind.
enum Audit {
    struct Item: Sendable, Hashable {
        /// From the folder being checked.
        var path: String
        var size: Int64
        var xxh64: String
        /// The camera's name, and the card it came from.
        var original: String
        var volume: String
    }

    struct Problem: Sendable, Hashable, Identifiable {
        enum Kind: Sendable, Hashable {
            case missing
            case resized(Int64)
            case changed(String)
            case unreadable(String)
        }
        var item: Item
        var kind: Kind
        var id: String { item.path }

        var sentence: String {
            switch kind {
            case .missing: "N'est plus là."
            case .resized(let size): "Fait \(Format.bytes(size)) au lieu de \(Format.bytes(item.size))."
            case .changed(let hash): "Ne se lit plus pareil : xxh64 \(hash) au lieu de \(item.xxh64)."
            case .unreadable(let message): message
            }
        }
    }

    struct Report: Sendable {
        var root: URL
        var records = 0
        var checked = 0
        var bytes: Int64 = 0
        var problems: [Problem] = []
        var cancelled = false
        var started = Date()
        var finished = Date()

        var intact: Int { checked - problems.count }
        var succeeded: Bool { problems.isEmpty && !cancelled && records > 0 }
    }

    struct Progress: Sendable {
        var done: Int64 = 0
        var total: Int64 = 0
        var filesDone = 0
        var filesTotal = 0
        var current = ""
        var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
    }

    /// Every file the records under `root` list, the last record's word for
    /// each path. The count of records is returned with them, so a folder with
    /// none can say so rather than "everything is fine".
    static func items(under root: URL) -> (items: [Item], records: Int) {
        var found: [String: Item] = [:]
        var records = 0
        let depth = root.standardizedFileURL.pathComponents.count
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = walker?.nextObject() as? URL {
            guard url.lastPathComponent == History.folderName else { continue }
            walker?.skipDescendants()
            let shoot = url.deletingLastPathComponent()
            let prefix = shoot.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            records += names.filter { $0.hasSuffix(".json") }.count
            for entry in History.entries(in: shoot) {
                let path = prefix.isEmpty ? entry.path : prefix + "/" + entry.path
                found[path] = Item(path: path, size: entry.size, xxh64: entry.xxh64, original: entry.original, volume: entry.volume)
            }
        }
        return (found.values.sorted { $0.path < $1.path }, records)
    }

    static func run(
        _ root: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Progress) -> Void
    ) -> Report {
        var report = Report(root: root)
        let (items, records) = items(under: root)
        report.records = records
        var state = Progress(total: items.reduce(0) { $0 + $1.size }, filesTotal: items.count)
        progress(state)
        var last = Date.distantPast

        for item in items {
            if isCancelled() {
                report.cancelled = true
                break
            }
            state.current = (item.path as NSString).lastPathComponent
            let before = state.done
            progress(state)
            let url = root.appendingPathComponent(item.path)
            var status = stat()
            if stat(url.path, &status) != 0 {
                report.problems.append(Problem(item: item, kind: .missing))
            } else if Int64(status.st_size) != item.size {
                report.problems.append(Problem(item: item, kind: .resized(Int64(status.st_size))))
            } else {
                do {
                    let hash = try Copier.hash(of: url, isCancelled: isCancelled) { bytes in
                        state.done += bytes
                        if Date().timeIntervalSince(last) > 0.1 {
                            last = Date()
                            progress(state)
                        }
                    }
                    if hash != item.xxh64 {
                        report.problems.append(Problem(item: item, kind: .changed(hash)))
                    }
                    report.bytes += item.size
                } catch is CancellationError {
                    report.cancelled = true
                    break
                } catch {
                    report.problems.append(Problem(item: item, kind: .unreadable(error.localizedDescription)))
                }
            }
            // Whatever it found, the bar moves past the file.
            state.done = before + item.size
            report.checked += 1
            state.filesDone += 1
            progress(state)
        }
        report.finished = Date()
        return report
    }
}
