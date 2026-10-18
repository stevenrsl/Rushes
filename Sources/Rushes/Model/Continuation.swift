import Foundation

/// The shoot tonight's cards carry on, when a drive remembers one.
///
/// The morning's cards were backed up at lunch; the evening's come back under
/// the same client and project, and their numbers carry on after the
/// morning's (`Planner`). That holds only if the fields still say so: typed
/// over since, for another job, and the evening goes into a folder of its own
/// from 0001. So the drives' journals are asked which shoot these cards
/// belong to, and the page offers it back in one click (asked 2026-10-16).
///
/// Two ways to know. A card that holds shots already saved belongs to the
/// backup that saved them, whatever day it is. A card with nothing saved yet
/// belongs to the last backup of the same shoot day, the card's own. Neither
/// is a guess about the client: both are what was typed at the time.
struct ShootContinuation: Sendable, Equatable {
    var client: String
    var project: String
    var initials: String
    /// When that backup started.
    var at: Date
    /// Files it verified.
    var files: Int
    /// Shots of tonight's cards it already holds: the reason it is offered.
    /// Zero when it was found by its day alone.
    var shotsSaved: Int
    /// The fields as typed already name it: said, not offered.
    var matches: Bool

    var title: String {
        let client = client.trimmingCharacters(in: .whitespaces)
        let project = project.trimmingCharacters(in: .whitespaces)
        return [client, project].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func find(
        sources: [PlanSource],
        days: [ShootDay],
        settings: IngestSettings,
        drives: [URL],
        journal: (URL) -> DriveJournal = DriveJournal.load
    ) -> ShootContinuation? {
        let journals = drives.map(journal)
        let shoots = journals.flatMap(\.shoots)
        guard !shoots.isEmpty else { return nil }

        // The backups that already hold some of these cards' shots.
        var holding: [String: Int] = [:]
        for source in sources {
            for group in source.groups {
                guard let fingerprint = group.files.first(where: \.role.isPrimary)?.fingerprint else { continue }
                for journal in journals {
                    if let backup = journal.saved[fingerprint]?.backup, !backup.isEmpty {
                        holding[backup, default: 0] += 1
                        break
                    }
                }
            }
        }
        let byID = Dictionary(shoots.map { ($0.backup, $0) }, uniquingKeysWith: { a, _ in a })
        var found: (shoot: DriveJournal.Shoot, saved: Int)?
        for (id, n) in holding {
            guard let shoot = byID[id] else { continue }
            if let best = found, best.saved > n || (best.saved == n && best.shoot.at >= shoot.at) { continue }
            found = (shoot, n)
        }
        if found == nil {
            // Nothing saved yet: the last backup of one of these cards' days.
            let wanted = Set(days)
            found = shoots.filter { shoot in
                let theirs = shoot.days.isEmpty ? [ShootDay(date: shoot.at, cutoffHour: settings.dayCutoffHour)] : shoot.days
                return !wanted.isDisjoint(with: theirs)
            }.max { $0.at < $1.at }.map { ($0, 0) }
        }
        guard let (shoot, saved) = found,
              !Sanitize.field(shoot.client).isEmpty || !Sanitize.field(shoot.project).isEmpty
        else { return nil }
        let matches = Sanitize.field(shoot.client).lowercased() == Sanitize.field(settings.client).lowercased()
            && Sanitize.field(shoot.project).lowercased() == Sanitize.field(settings.project).lowercased()
        return ShootContinuation(
            client: shoot.client, project: shoot.project, initials: shoot.initials, at: shoot.at,
            files: shoot.files, shotsSaved: saved, matches: matches
        )
    }
}
