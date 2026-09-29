import Foundation

/// Why ⌘↩ is not ready, the most useful reason first.
///
/// This is the gate before a night's copy: every reason here is a way the
/// backup would fail at 3 a.m., copy under the wrong name, or claim two copies
/// where there is one. It is a plain value, made from what `Ingest` shows, so
/// each rule can be tested without a window, a card or a drive.
struct Readiness {
    struct Drive {
        var name: String
        var isOnline: Bool
        var available: Int64?
        var fileSystem: String?
        /// The path of the volume it sits on.
        var volume: String
    }

    var cards: Int
    var scanning: Bool
    /// A plan is being made, or the one on screen is not the current one.
    var planning: Bool
    /// Cards ticked and read.
    var ready: Int
    var cardWithoutLetter: Bool
    var drives: [Drive]
    var settings: IngestSettings
    var plan: IngestPlan

    /// A disk filled to its last byte fails in the middle of the night, and
    /// the folders, the manifests and exFAT's large clusters all take a little
    /// more than the files themselves.
    static func margin(for bytes: Int64) -> Int64 { max(64 << 20, bytes / 100) }

    var blockers: [String] {
        var reasons: [String] = []
        let template = NameTemplate(settings.namePattern)
        if cards == 0 { reasons.append("Insère une carte ou ajoute un dossier.") }
        else if scanning { reasons.append("Lecture des cartes en cours…") }
        else if planning { reasons.append("Préparation de l'aperçu…") }
        else if ready == 0 { reasons.append("Aucune carte sélectionnée.") }
        if drives.isEmpty { reasons.append("Choisis un disque de destination.") }
        for drive in drives where !drive.isOnline { reasons.append("« \(drive.name) » n'est pas branché.") }
        let missing: [(NameToken, String)] = [(.initials, settings.initials), (.client, settings.client), (.project, settings.project)]
        for (token, value) in missing where template.uses(token) || NameTemplate(settings.folderPattern).uses(token) || settings.layout.uses(token) {
            if Sanitize.field(value).isEmpty { reasons.append("Il manque \(token == .initials ? "tes initiales" : token == .client ? "le client" : "le projet").") }
        }
        if template.uses(.camera) || settings.layout.uses(.camera), cardWithoutLetter { reasons.append("Une carte n'a pas de lettre de caméra.") }
        if !template.isUnique { reasons.append("Le modèle doit contenir {NUM} ou {ORIG}, sinon deux photos auraient le même nom.") }
        if !plan.conflicts.isEmpty { reasons.append("\(plan.conflicts.count) nom\(plan.conflicts.count > 1 ? "s" : "") déjà pris : rien ne sera remplacé.") }
        let online = drives.filter(\.isOnline)
        for drive in online {
            let needed = plan.bytesToCopy + Self.margin(for: plan.bytesToCopy)
            if let free = drive.available, free < needed {
                reasons.append("Pas assez de place sur « \(drive.name) » : il manque \(Format.bytes(needed - free)).")
            }
        }
        if let big = plan.tooBigForFAT {
            for drive in online where drive.fileSystem == "msdos" {
                reasons.append("« \(drive.name) » est en FAT32, qui ne peut pas recevoir « \(big.name) » (\(Format.bytes(big.file.size))) : il faut un disque en exFAT ou APFS.")
            }
        }
        // Two folders on one disk are one copy, however they are named. Saying
        // "sur deux disques" then would be the one lie that matters.
        var volumes: [String: String] = [:]
        for drive in online {
            if let first = volumes[drive.volume], first != drive.name {
                reasons.append("« \(first) » et « \(drive.name) » sont sur le même disque : ce ne serait qu'une seule copie.")
            } else if volumes[drive.volume] == nil {
                volumes[drive.volume] = drive.name
            }
        }
        // The copy in progress is named `.<name>.rushes-partial`, sixteen
        // characters longer: a name the drive would accept, but its partial
        // not, fails file by file all night.
        if let long = plan.toCopy.flatMap(\.files).first(where: { $0.name.utf8.count + 16 > 255 }) {
            reasons.append("« \(long.name) » est trop long pour être écrit : raccourcis le modèle de nom.")
        }
        if reasons.isEmpty, plan.toCopy.isEmpty, !plan.groups.isEmpty {
            if plan.unticked == plan.groups.count {
                reasons.append("Aucun type de fichier coché dans Fichiers.")
            } else if plan.unticked > 0 {
                reasons.append("Rien de nouveau parmi les types cochés.")
            } else {
                reasons.append("Tout est déjà sauvegardé sur chaque disque.")
            }
        }
        return reasons
    }
}
