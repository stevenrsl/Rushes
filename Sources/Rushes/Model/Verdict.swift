import Foundation

/// What a card is told at the end of a backup: whether it can be formatted.
///
/// It is the one sentence the whole app is for. A card is formatted in the
/// camera, by hand, hours later, and nothing can be undone afterwards, so the
/// verdict is per card and never a general "c'est bon". It is calculated from
/// what actually happened to that card's own files, and it says what is still
/// only on it.
struct CardVerdict: Identifiable, Sendable {
    enum Level: Sendable {
        /// Everything ticked was copied and verified on every drive.
        case safe
        /// Nothing failed, but something is on this card and nowhere else,
        /// and it was never anyone's choice: a file of a kind Rushes does not
        /// know cannot be ticked.
        case check
        /// Something of this card was meant to be copied and was not.
        case hold
    }

    let cardID: String
    let cardName: String
    let level: Level
    /// Why it is not plainly formattable, in the order they matter.
    let reasons: [String]
    /// Files left on the card on purpose: kinds left unticked, the camera's
    /// proxies and thumbnails, companions with no shot of their own.
    let leftByChoice: Int

    var id: String { cardID }

    var title: String {
        switch level {
        case .safe: "Formatable"
        case .check: "À vérifier"
        case .hold: "Ne pas formater"
        }
    }

    /// One line, written to be read at three in the morning.
    var sentence: String {
        switch level {
        case .safe:
            var text = "Tout est sur chaque disque, relu et vérifié. Tu peux formater cette carte dans l'appareil."
            if leftByChoice > 0 {
                text += " \(Format.count(leftByChoice, "fichier")) \(leftByChoice > 1 ? "restent" : "reste") dessus par choix."
            }
            return text
        case .check, .hold:
            return reasons.joined(separator: " ")
        }
    }
}

enum Verdicts {
    /// The verdict for one card, from its own scan, the plan and the report.
    /// Only this card's files count: another card that failed does not keep
    /// this one from being formatted.
    static func of(
        cardID: String,
        cardName: String,
        scan: CardScan,
        plan: IngestPlan,
        report: BackupReport
    ) -> CardVerdict {
        var reasons: [String] = []
        var level = CardVerdict.Level.safe

        let failures = report.failures.filter { $0.source == cardID }
        if !failures.isEmpty {
            level = .hold
            reasons.append("\(Format.count(failures.count, "fichier")) de cette carte \(failures.count > 1 ? "n'ont" : "n'a") pas pu être copié\(failures.count > 1 ? "s" : "").")
        }

        let mine = plan.groups.filter { $0.sourceID == cardID }
        let wanted = mine.filter { $0.status == .new }
        if !wanted.isEmpty, report.cancelled || report.stopped != nil {
            level = .hold
            reasons.append(report.cancelled
                ? "La sauvegarde a été interrompue avant la fin de cette carte."
                : "La sauvegarde s'est arrêtée avant la fin de cette carte.")
        }

        if !scan.isComplete {
            level = .hold
            let folders = Format.count(scan.unreadableFolders.count, "dossier")
            reasons.append("Cette carte n'a pas été lue entièrement : \(folders) illisible\(scan.unreadableFolders.count > 1 ? "s" : "").")
        }

        if !scan.unknown.isEmpty {
            if level == .safe { level = .check }
            let kinds = Set(scan.unknown.map(\.ext).filter { !$0.isEmpty }).sorted()
            let named = kinds.isEmpty ? "" : " (\(kinds.prefix(3).joined(separator: ", ")))"
            reasons.append("\(Format.count(scan.unknown.count, "fichier")) d'un type que Rushes ne connaît pas\(named) \(scan.unknown.count > 1 ? "restent" : "reste") sur la carte : \(scan.unknown.count > 1 ? "copie-les" : "copie-le") à la main avant de formater.")
        }

        if !plan.conflicts.isEmpty, mine.contains(where: { if case .conflict = $0.status { true } else { false } }) {
            level = .hold
            reasons.append("Des noms de cette carte étaient déjà pris : ces prises n'ont pas été copiées.")
        }

        let leftByChoice = mine.reduce(0) { $0 + $1.leftOut.count } + scan.orphans.count
        return CardVerdict(cardID: cardID, cardName: cardName, level: level, reasons: reasons, leftByChoice: leftByChoice)
    }
}
