import Darwin
import Foundation

/// Deletes from a card the files that are on every drive, and nothing else.
///
/// The second door Steven opened on the rule that a card is only read
/// (2026-10-16), beside the format: some bodies keep settings, a GPS log or a
/// clip nobody ticked on the card, and a format takes them too. So the done
/// page can also empty a card of what the backup saved, one card at a time,
/// after a destructive confirmation.
///
/// Nothing is taken on the record's word. At the moment of deleting, the card
/// is still the volume that was read, each file on it still has the size and
/// the date it was copied with, and each copy is still lying on every drive,
/// at that size. A file that fails any of it stays. What was left on purpose
/// (an unticked kind, a proxy, a file Rushes does not know) is never listed.
enum CardCleanup {
    struct Item: Sendable, Hashable {
        /// On the card.
        let source: URL
        let size: Int64
        /// Whole seconds, as the fingerprint holds it.
        let modified: Int
        /// Every drive's copy.
        let copies: [URL]
    }

    struct Result: Sendable {
        var deleted = 0
        var bytes: Int64 = 0
        /// Files left on the card, and why, by card path.
        var kept: [(path: String, reason: String)] = []
    }

    /// The files of one card that this backup verified on every drive, or
    /// that an earlier one did and the journal can still point to.
    static func items(
        cardID: String,
        plan: IngestPlan,
        report: BackupReport,
        drives: [URL],
        journal: (URL) -> DriveJournal = DriveJournal.load
    ) -> [Item] {
        guard !drives.isEmpty else { return [] }
        let verified = Set(report.entries.values.flatMap { $0.map(\.fingerprint) })
        let failed = Set(report.failures.map(\.file))
        var items: [Item] = []
        for group in plan.groups where group.sourceID == cardID {
            // Its own drives: those that receive its kind of shot. A plan
            // that names none (made before 0.6) means all of them.
            let mine = group.drives.isEmpty ? drives : drives.filter { group.drives.contains($0.path) }
            guard !mine.isEmpty else { continue }
            switch group.status {
            case .new:
                for planned in group.files where verified.contains(planned.file.fingerprint) && !failed.contains(planned.file.relativePath) {
                    items.append(item(planned.file, copies: mine.map { $0.appendingPathComponent(planned.relativePath) }))
                }
            case .alreadyCopied:
                let left = Set(group.leftOut.map(\.id))
                for file in group.group.files where !left.contains(file.id) {
                    let copies = mine.compactMap { drive in
                        journal(drive).saved[file.fingerprint].map { drive.appendingPathComponent($0.path) }
                    }
                    // A copy the journal cannot place is not counted as one.
                    guard copies.count == mine.count else { continue }
                    items.append(item(file, copies: copies))
                }
            case .conflict, .unticked, .noDrive:
                continue
            }
        }
        return items
    }

    private static func item(_ file: MediaFile, copies: [URL]) -> Item {
        Item(source: file.url, size: file.size, modified: Int(file.modified.timeIntervalSince1970.rounded(.down)), copies: copies)
    }

    /// Checks every item again and deletes those that pass, on a card that
    /// must still be `identity`, never one of `avoiding`.
    static func run(_ items: [Item], card: URL, identity: String, avoiding: Set<String>) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            guard card.path != "/", !avoiding.contains(card.path) else {
                throw VolumeWatcher.FormatRefusal(message: "c'est une destination de la sauvegarde.")
            }
            guard VolumeWatcher.identity(of: card) == identity else {
                throw VolumeWatcher.FormatRefusal(message: "la carte dans le lecteur n'est plus celle qui a été sauvegardée.")
            }
            var result = Result()
            let root = card.standardizedFileURL.path + "/"
            for item in items {
                let path = item.source.standardizedFileURL.path
                let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
                guard path.hasPrefix(root) else {
                    result.kept.append((relative, "pas sur cette carte"))
                    continue
                }
                if let reason = refusal(item) {
                    result.kept.append((relative, reason))
                    continue
                }
                if unlink(path) == 0 {
                    result.deleted += 1
                    result.bytes += item.size
                } else {
                    result.kept.append((relative, String(cString: strerror(errno))))
                }
            }
            return result
        }.value
    }

    /// Why this file must stay, or nil when it may go.
    static func refusal(_ item: Item) -> String? {
        var card = stat()
        guard lstat(item.source.path, &card) == 0, (card.st_mode & S_IFMT) == S_IFREG else {
            return "introuvable sur la carte"
        }
        guard card.st_size == item.size, Int(card.st_mtimespec.tv_sec) == item.modified else {
            return "a changé sur la carte depuis la copie"
        }
        for copy in item.copies {
            var status = stat()
            guard stat(copy.path, &status) == 0 else { return "copie introuvable sur \(drive(of: copy))" }
            guard status.st_size == item.size else { return "copie d'une autre taille sur \(drive(of: copy))" }
        }
        return nil
    }

    private static func drive(of url: URL) -> String {
        VolumeWatcher.volume(of: url).map(\.lastPathComponent) ?? url.deletingLastPathComponent().lastPathComponent
    }
}
