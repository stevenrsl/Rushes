import SwiftUI

/// Every file, the name it will get and where it goes, before anything is
/// written. What stays on the card is listed too: a backup never leaves a
/// file out without saying so.
struct PreviewBlock: View {
    @Environment(Ingest.self) private var ingest
    @State private var filter: Filter = .toCopy
    /// The whole list, asked for. Ten rows by default: a table of ten
    /// thousand was laid out again at every setting changed, and the window
    /// froze while it was (reported 2026-10-17). The chips keep the counts.
    @State private var showAll = false
    static let shown = 10

    enum Filter: Hashable {
        case toCopy, saved, leftOut, conflicts
    }

    typealias Row = PreviewRows.Row

    var body: some View {
        let all = ingest.preview.rows(for: filter)
        let rows = showAll ? all : Array(all.prefix(Self.shown))
        VStack(alignment: .leading, spacing: 14) {
            Flow(spacing: 6) {
                Chip(text: "À copier", count: ingest.plan.filesToCopy, selected: filter == .toCopy) { filter = .toCopy }
                if ingest.plan.alreadyCopied > 0 {
                    Chip(text: "Déjà sauvegardés", count: ingest.plan.alreadyCopied, selected: filter == .saved) { filter = .saved }
                }
                if ingest.preview.leftOut.count > 0 {
                    Chip(text: "Laissés sur la carte", count: ingest.preview.leftOut.count, selected: filter == .leftOut) { filter = .leftOut }
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
                .frame(minHeight: showAll ? 260 : 120, idealHeight: showAll ? 360 : 290, maxHeight: showAll ? 460 : 290)
                // The one container of the page: the rows scroll inside it.
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Palette.hairline))
            }
            HStack(spacing: 10) {
                Text(all.count > Self.shown && !showAll
                    ? "Les \(Self.shown) premiers sur \(all.count). Rien n'est écrit avant d'appuyer sur Sauvegarder."
                    : "Rien n'est écrit avant d'appuyer sur Sauvegarder.")
                    .font(TypeScale.micro)
                    .foregroundStyle(Palette.inkFaint)
                if all.count > Self.shown {
                    Button(showAll ? "Afficher moins" : "Tout afficher") { showAll.toggle() }
                        .buttonStyle(.accentLink)
                        .font(TypeScale.micro)
                }
            }
        }
        .onChange(of: filter) { showAll = false }
        .onChange(of: ingest.plan.conflicts.isEmpty) { _, empty in
            if !empty { filter = .conflicts } else if filter == .conflicts { filter = .toCopy }
        }
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
}

/// The preview's rows, every filter at once, made with the plan off the main
/// thread. Made in the view, they were made again at every redraw, which on a
/// card of ten thousand shots is every keystroke and every tick of the scan.
struct PreviewRows: Sendable {
    struct Row: Identifiable, Sendable {
        enum Status: Sendable { case new, saved, leftOut, conflict }
        let id: String
        let status: Status
        let name: String
        let original: String
        let folder: String
        let size: Int64
        let camera: String
        let note: String
    }

    var toCopy: [Row] = []
    var saved: [Row] = []
    var leftOut: [Row] = []
    var conflicts: [Row] = []

    func rows(for filter: PreviewBlock.Filter) -> [Row] {
        switch filter {
        case .toCopy: toCopy
        case .saved: saved
        case .leftOut: leftOut
        case .conflicts: conflicts
        }
    }

    init() {}

    init(plan: IngestPlan, sources: [PlanSource], settings: IngestSettings) {
        let labels = Dictionary(sources.map { ($0.id, $0.cameraLabel) }, uniquingKeysWith: { a, _ in a })
        func label(_ id: String) -> String { labels[id] ?? "" }
        toCopy = plan.toCopy.flatMap { group in
            group.files.map { planned in
                Row(id: planned.id, status: .new, name: planned.name, original: planned.file.name,
                    folder: (planned.relativePath as NSString).deletingLastPathComponent,
                    size: planned.file.size, camera: label(group.sourceID), note: planned.file.relativePath)
            }
        }
        saved = plan.groups.filter { $0.status == .alreadyCopied }.flatMap { group in
            let leftOut = Set(group.leftOut.map(\.id))
            return group.group.files.filter { !leftOut.contains($0.id) }.map { file in
                Row(id: file.id, status: .saved, name: file.name, original: file.relativePath,
                    folder: group.shootFolder, size: file.size, camera: label(group.sourceID),
                    note: "Sur chaque disque, retrouvé à la bonne taille dans \((group.savedIn ?? group.shootFolder).isEmpty ? "la destination" : group.savedIn ?? group.shootFolder)")
            }
        }
        leftOut = plan.groups.flatMap { group in
            group.leftOut.map { file in
                Row(id: file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                    size: file.size, camera: label(group.sourceID), note: Self.reason(file, settings))
            }
        }
        for source in sources {
            for file in source.orphans {
                leftOut.append(Row(id: file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                                   size: file.size, camera: source.cameraLabel, note: "Fichier de la carte, sans photo ni vidéo à qui appartenir"))
            }
            for file in source.unknown {
                leftOut.append(Row(id: source.id + "/" + file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                                   size: file.size, camera: source.cameraLabel,
                                   note: file.ext.isEmpty ? "Type de fichier inconnu de Rushes" : "« \(file.ext) » : type de fichier inconnu de Rushes"))
            }
            for file in source.setAside {
                leftOut.append(Row(id: source.id + "/" + file.id, status: .leftOut, name: file.name, original: file.relativePath, folder: "",
                                   size: file.size, camera: source.cameraLabel,
                                   note: (file.hiddenBy ?? "").isEmpty
                                       ? "Caché par l'appareil : à copier à la main si c'est une prise"
                                       : "Dans « \(file.hiddenBy!) », où l'appareil range ses propres fichiers"))
            }
        }
        conflicts = plan.conflicts.flatMap { group in
            group.files.map { planned in
                var note = ""
                if case .conflict(let message) = group.status { note = message }
                return Row(id: planned.id, status: .conflict, name: planned.name, original: planned.file.name,
                           folder: (planned.relativePath as NSString).deletingLastPathComponent,
                           size: planned.file.size, camera: label(group.sourceID), note: note)
            }
        }
    }

    private static func reason(_ file: MediaFile, _ settings: IngestSettings) -> String {
        switch file.role {
        case .proxy: "Proxy de l'appareil : « \(file.kind.ext) » non coché dans Fichiers"
        case .thumbnail: "Vignette de l'appareil : non cochée dans Fichiers"
        default: settings.includes(file.kind)
            ? "Suit sa prise, dont aucun fichier principal n'est coché"
            : "« \(file.kind.ext) » non coché dans Fichiers"
        }
    }
}
