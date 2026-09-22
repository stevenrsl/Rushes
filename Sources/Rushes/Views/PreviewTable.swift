import SwiftUI

/// Every file, the name it will get and where it goes, before anything is
/// written. What stays on the card is listed too: a backup never leaves a
/// file out without saying so.
struct PreviewBlock: View {
    @Environment(Ingest.self) private var ingest
    @State private var filter: Filter = .toCopy

    enum Filter: Hashable {
        case toCopy, saved, leftOut, conflicts
    }

    struct Row: Identifiable {
        enum Status { case new, saved, leftOut, conflict }
        let id: String
        let status: Status
        let name: String
        let original: String
        let folder: String
        let size: Int64
        let camera: String
        let note: String
    }

    var body: some View {
        let rows = rows(for: filter)
        VStack(alignment: .leading, spacing: 14) {
            Flow(spacing: 6) {
                Chip(text: "À copier", count: ingest.plan.filesToCopy, selected: filter == .toCopy) { filter = .toCopy }
                if ingest.plan.alreadyCopied > 0 {
                    Chip(text: "Déjà sauvegardés", count: ingest.plan.alreadyCopied, selected: filter == .saved) { filter = .saved }
                }
                if leftOutCount > 0 {
                    Chip(text: "Laissés sur la carte", count: leftOutCount, selected: filter == .leftOut) { filter = .leftOut }
                }
                if !ingest.plan.conflicts.isEmpty {
                    Chip(text: "Conflits", count: ingest.plan.conflicts.count, selected: filter == .conflicts) { filter = .conflicts }
                }
            }
            if rows.isEmpty {
                Text(emptyText)
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Table(rows) {
                    TableColumn("") { row in
                        CameraBadge(label: row.camera).scaleEffect(0.85)
                    }
                    .width(26)
                    TableColumn(filter == .toCopy || filter == .conflicts ? "Nouveau nom" : "Fichier") { row in
                        Text(row.name)
                            .font(TypeScale.code)
                            .foregroundStyle(color(row.status))
                            .help(row.note)
                    }
                    .width(min: 200, ideal: 290)
                    TableColumn("Origine") { row in
                        Text(row.original)
                            .font(TypeScale.code)
                            .foregroundStyle(Palette.inkSoft)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn(filter == .leftOut ? "Pourquoi" : "Dossier") { row in
                        let text = filter == .leftOut || filter == .conflicts ? row.note : row.folder
                        Text(text)
                            .font(TypeScale.meta)
                            .foregroundStyle(Palette.inkFaint)
                            // The end of a path says where the file lands: RAW or JPG.
                            .truncationMode(filter == .toCopy || filter == .saved ? .head : .tail)
                            .help(text)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Taille") { row in
                        Text(Format.bytes(row.size))
                            .font(TypeScale.meta)
                            .foregroundStyle(Palette.inkFaint)
                            .monospacedDigit()
                    }
                    .width(64)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260, idealHeight: 360, maxHeight: 460)
                // The one container of the page: the rows scroll inside it.
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Palette.hairline))
            }
            Text("Rien n'est écrit avant d'appuyer sur Sauvegarder.")
                .font(TypeScale.micro)
                .foregroundStyle(Palette.inkFaint)
        }
        .onChange(of: ingest.plan.conflicts.isEmpty) { _, empty in
            if !empty { filter = .conflicts } else if filter == .conflicts { filter = .toCopy }
        }
    }

    private var leftOutCount: Int {
        ingest.plan.leftOutCount + ingest.readyCards.reduce(0) { $0 + ($1.scan?.orphans.count ?? 0) + ($1.scan?.unknown.count ?? 0) }
    }

    private var emptyText: String {
        if ingest.cards.isEmpty { return "Les fichiers de la carte apparaîtront ici." }
        if ingest.isScanning { return "Lecture de la carte…" }
        if ingest.isPlanning { return "Préparation de l'aperçu…" }
        return filter == .toCopy ? "Rien de nouveau à copier." : "Rien ici."
    }

    private func color(_ status: Row.Status) -> Color {
        switch status {
        case .new: Palette.ink
        case .saved: Palette.accentInk
        case .leftOut: Palette.inkFaint
        case .conflict: Palette.alert
        }
    }

    private func label(for sourceID: String) -> String {
        ingest.cards.first { $0.id == sourceID }?.cameraLabel ?? ""
    }

    private func rows(for filter: Filter) -> [Row] {
        let plan = ingest.plan
        switch filter {
        case .toCopy:
            return plan.toCopy.flatMap { group in
                group.files.map { planned in
                    Row(id: planned.id, status: .new, name: planned.name, original: planned.file.name,
                        folder: (planned.relativePath as NSString).deletingLastPathComponent,
                        size: planned.file.size, camera: label(for: group.sourceID), note: planned.file.relativePath)
                }
            }
        case .saved:
            return plan.groups.filter { $0.status == .alreadyCopied }.flatMap { group in
                group.group.files.filter { !group.leftOut.contains($0) }.map { file in
                    Row(id: file.id, status: .saved, name: file.name, original: file.relativePath,
                        folder: group.shootFolder, size: file.size, camera: label(for: group.sourceID),
                        note: "Sur chaque disque, retrouvé à la bonne taille dans \(group.shootFolder.isEmpty ? "la destination" : group.shootFolder)")
                }
            }
        case .leftOut:
            let settings = ingest.settings
            var rows = plan.groups.flatMap { group in
                group.leftOut.map { file in
                    Row(id: file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                        size: file.size, camera: label(for: group.sourceID), note: reason(file, settings))
                }
            }
            for card in ingest.readyCards {
                for file in card.scan?.orphans ?? [] {
                    rows.append(Row(id: file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                                    size: file.size, camera: card.cameraLabel, note: "Fichier de la carte, sans photo ni vidéo à qui appartenir"))
                }
                for file in card.scan?.unknown ?? [] {
                    rows.append(Row(id: card.id + "/" + file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                                    size: file.size, camera: card.cameraLabel,
                                    note: file.ext.isEmpty ? "Type de fichier inconnu de Rushes" : "« \(file.ext) » : type de fichier inconnu de Rushes"))
                }
            }
            return rows
        case .conflicts:
            return plan.conflicts.flatMap { group in
                group.files.map { planned in
                    var note = ""
                    if case .conflict(let message) = group.status { note = message }
                    return Row(id: planned.id, status: .conflict, name: planned.name, original: planned.file.name,
                               folder: (planned.relativePath as NSString).deletingLastPathComponent,
                               size: planned.file.size, camera: label(for: group.sourceID), note: note)
                }
            }
        }
    }

    private func reason(_ file: MediaFile, _ settings: IngestSettings) -> String {
        switch file.role {
        case .proxy: "Proxy de l'appareil : « \(file.kind.ext) » non coché dans Fichiers"
        case .thumbnail: "Vignette de l'appareil : non cochée dans Fichiers"
        default: settings.includes(file.kind)
            ? "Suit sa prise, dont aucun fichier principal n'est coché"
            : "« \(file.kind.ext) » non coché dans Fichiers"
        }
    }
}
