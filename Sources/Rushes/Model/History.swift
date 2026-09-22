import Foundation

/// The record each backup leaves in the shoot's folder, on every drive:
/// `_RUSHES/260922-031204.json` for Rushes and `.csv` for a person.
///
/// It is the only place the camera's names survive the renaming, so a client
/// asking for "DSC01234" can still be answered, and it is how a card that was
/// not formatted is recognised the next night: files whose fingerprint is
/// already listed on every drive are not copied again. It lives with the
/// files, not on the Mac, so it travels with the drive.
struct Manifest: Codable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        /// The path on the card, `DCIM/100MSDCF/DSC01234.ARW`.
        var original: String
        /// The card's name as the Mac saw it.
        var volume: String
        /// Where the file is, from the shoot's folder.
        var path: String
        var size: Int64
        var xxh64: String
        var fingerprint: String
        var captured: Date
    }

    var app = "Rushes"
    var version = 1
    var created: Date
    var entries: [Entry]
}

enum History {
    static let folderName = "_RUSHES"

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Every file listed under a shoot's folder, newest record last: what was
    /// saved there, where it was put and how big it was. A record says what
    /// happened one night; whether the file is still there is another question,
    /// and the planner answers it by looking (see `DestinationIndex`).
    static func entries(in shootFolder: URL) -> [Manifest.Entry] {
        let folder = shootFolder.appendingPathComponent(folderName)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var found: [Manifest.Entry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let manifest = try? decoder.decode(Manifest.self, from: data)
            else { continue }
            found.append(contentsOf: manifest.entries)
        }
        return found
    }

    /// Writes the record of one backup in one shoot's folder. A second backup
    /// the same second (two cards back to back) gets its own name.
    static func write(_ entries: [Manifest.Entry], in shootFolder: URL, at date: Date) throws {
        guard !entries.isEmpty else { return }
        let folder = shootFolder.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = stamp(date)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(base + ".json").path) {
            base = stamp(date) + "-\(n)"
            n += 1
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(Manifest(created: date, entries: entries))
        try json.write(to: folder.appendingPathComponent(base + ".json"), options: .atomic)

        // Semicolons, because Numbers and Excel set to French read commas as decimals.
        let iso = ISO8601DateFormatter()
        var csv = "fichier;origine;carte;taille;xxh64;prise de vue\n"
        for e in entries {
            let fields = [e.path, e.original, e.volume, String(e.size), e.xxh64, iso.string(from: e.captured)]
            csv += fields.map { $0.contains(";") ? "\"\($0)\"" : $0 }.joined(separator: ";") + "\n"
        }
        try Data(csv.utf8).write(to: folder.appendingPathComponent(base + ".csv"), options: .atomic)
    }
}
