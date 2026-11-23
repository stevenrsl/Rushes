import Foundation

/// The days a backup's cards hold, told apart: tonight's shoot, and the few
/// shots left on a card from another day.
///
/// "Parfois, on peut avoir une ou deux photos qui traînent encore sur la carte
/// SD et ça casse tout" (Steven, 2026-11-23). A card never formatted, or kept
/// on purpose, brings two photos of the 14th beside three hundred of the 23rd.
/// Filed by their own day, as before, they made a second shoot folder named
/// with tonight's client; a day fixed by hand took them in as 0001 and 0002;
/// and when they were already saved, the backup that saved them was offered
/// as the shoot tonight carries on. So the days are grouped into runs (days
/// at most two apart, a day off in a shoot of several), the run with the most
/// shots is the shoot, and every other day is said on the page with a choice.
struct DaySpread: Sendable, Equatable {
    struct Straggler: Sendable, Equatable, Identifiable {
        let day: ShootDay
        var photos = 0
        var videos = 0
        var sounds = 0
        /// Filled by the planner: shots of this day already on every drive,
        /// the folder they were found in, and the folder the others go to.
        var saved = 0
        var savedIn: String?
        var folder: String?
        var allSaved: Bool { shots > 0 && saved == shots }
        var id: ShootDay { day }

        init(day: ShootDay) { self.day = day }

        /// What these shots are, counted by kind.
        init(day: ShootDay, groups: [MediaGroup]) {
            self.day = day
            for group in groups { add(group) }
        }

        mutating func add(_ group: MediaGroup) {
            switch group.category {
            case .photo: photos += 1
            case .video: videos += 1
            case .audio: sounds += 1
            }
        }

        var shots: Int { photos + videos + sounds }

        /// "2 photos", "1 vidéo", "2 photos et 1 son".
        var described: String {
            var parts: [String] = []
            if photos > 0 { parts.append("\(photos) photo\(photos > 1 ? "s" : "")") }
            if videos > 0 { parts.append("\(videos) vidéo\(videos > 1 ? "s" : "")") }
            if sounds > 0 { parts.append("\(sounds) son\(sounds > 1 ? "s" : "")") }
            switch parts.count {
            case 0: return "aucune prise"
            case 1: return parts[0]
            default: return parts.dropLast().joined(separator: ", ") + " et " + parts.last!
            }
        }
    }

    /// The shoot's days, in order.
    var main: [ShootDay] = []
    /// Every other day, in order, with what it holds.
    var stragglers: [Straggler] = []
    /// The shoot's busiest day: where a straggler filed "avec ce tournage"
    /// goes when no day is fixed by hand.
    var target: ShootDay?

    /// Days further apart than this are two shoots.
    static let gap = 2

    func isStraggling(_ day: ShootDay) -> Bool { stragglers.contains { $0.day == day } }

    static func of(_ groups: [MediaGroup], cutoffHour: Int) -> DaySpread {
        var counts: [ShootDay: Straggler] = [:]
        for group in groups {
            let day = ShootDay(date: group.captureDate, cutoffHour: cutoffHour)
            counts[day, default: Straggler(day: day)].add(group)
        }
        let days = counts.keys.sorted()
        guard !days.isEmpty else { return DaySpread() }

        var runs: [[ShootDay]] = [[days[0]]]
        for day in days.dropFirst() {
            if let last = runs[runs.count - 1].last, distance(last, day) <= gap {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        // The most shots, and the latest when two runs hold as many: the
        // card was brought back tonight for tonight.
        let shots = { (run: [ShootDay]) in run.reduce(0) { $0 + counts[$1]!.shots } }
        let main = runs.enumerated().max { a, b in
            let x = shots(a.element), y = shots(b.element)
            return x != y ? x < y : a.offset < b.offset
        }!.element
        let mainSet = Set(main)
        let target = main.max { a, b in
            let x = counts[a]!.shots, y = counts[b]!.shots
            return x != y ? x < y : a < b
        }
        return DaySpread(
            main: main,
            stragglers: days.filter { !mainSet.contains($0) }.map { counts[$0]! },
            target: target
        )
    }

    private static func distance(_ a: ShootDay, _ b: ShootDay) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let from = calendar.date(from: DateComponents(year: a.year, month: a.month, day: a.day, hour: 12))!
        let to = calendar.date(from: DateComponents(year: b.year, month: b.month, day: b.day, hour: 12))!
        return abs(calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }
}

/// What becomes of the shots of a day apart from the shoot, chosen on the
/// preparation page for one backup and not remembered: the next card holds
/// other days.
enum DayFiling: String, Sendable, CaseIterable {
    /// Their own day: a folder and numbers of their own, as it always was.
    case ownDay
    /// Tonight's day, folder and numbers, after tonight's shots.
    case withShoot
    /// Not copied. The card is then "à vérifier", never formatable.
    case leave

    var title: String {
        switch self {
        case .ownDay: "À leur date"
        case .withShoot: "Avec ce tournage"
        case .leave: "Laissées sur la carte"
        }
    }
}
