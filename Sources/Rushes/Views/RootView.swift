import SwiftUI

struct RootView: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        NavigationSplitView {
            CardsColumn()
        } detail: {
            Group {
                switch ingest.phase {
                case .preparing: PrepareView()
                case .copying: CopyingView()
                case .finished(let report): DoneView(report: report)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageGround()
            .navigationTitle("Rushes")
            .toolbar(removing: .title)
            // The wash runs up under the traffic lights, one ground to the top.
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .tint(Palette.accentLine)
        .frame(minWidth: 960, minHeight: 680)
    }
}

/// The page before the backup, laid out as a Cairn page: where you are, a
/// title in serif, one sentence that says what will happen. Then one sheet:
/// sections on the ground, a hairline between them, their names in serif in a
/// column of their own. Only the preview has a container, because its rows
/// scroll (the redesign of 2026-09-21: five cards became one page).
private struct PrepareView: View {
    @Environment(Ingest.self) private var ingest
    @State private var width: CGFloat = 800

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PageTrail(steps: trail)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(TypeScale.display)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Text(sentence)
                        .font(TypeScale.aim)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let narrow = width < 620
                VStack(alignment: .leading, spacing: 0) {
                    PageSection(title: "Tournage", stacked: narrow) { ShootBlock() }
                    PageSection(title: "Destinations", stacked: narrow) { DrivesBlock() }
                    PageSection(title: "Fichiers", stacked: narrow) { FilesBlock() }
                    PageSection(title: "Nommage", stacked: narrow) { NamingBlock() }
                    PageSection(title: "Aperçu", stacked: true) { PreviewBlock() }
                }
                .padding(.top, 34)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
            .padding(.top, Page.top)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar()
        }
    }

    private var trail: [String] {
        var steps = [Format.sentenceDay(.now)]
        let cards = ingest.cards.count
        if cards > 0 { steps.append(Format.count(cards, "carte")) }
        return steps
    }

    /// The shoot, as it will be named: the client and the project as typed.
    private var title: String {
        let client = ingest.settings.client.trimmingCharacters(in: .whitespaces)
        let project = ingest.settings.project.trimmingCharacters(in: .whitespaces)
        switch (client.isEmpty, project.isEmpty) {
        case (false, false): return "\(client) · \(project)"
        case (false, true): return client
        case (true, false): return project
        case (true, true): return "Nouveau tournage"
        }
    }

    private var sentence: String {
        let plan = ingest.plan
        if ingest.cards.isEmpty { return "Insère une carte : elle apparaît à gauche, quelle que soit la marque." }
        if ingest.isScanning { return "Lecture des cartes…" }
        if ingest.isPlanning, plan.groups.isEmpty { return "Préparation de l'aperçu…" }
        if plan.filesToCopy == 0 {
            if plan.unticked == plan.groups.count, !plan.groups.isEmpty { return "Aucun type de fichier n'est coché." }
            return plan.alreadyCopied > 0 ? "Rien de nouveau : tout est déjà sur chaque disque." : "Rien à copier sur ces cartes."
        }
        var text = "\(Format.count(plan.filesToCopy, "fichier")), \(Format.bytes(plan.bytesToCopy))"
        let days = plan.days
        if days.count == 1 { text += ", du \(Format.day(days[0]))" } else if days.count > 1 { text += ", sur \(days.count) jours" }
        let drives = ingest.onlineDrives.map(\.name)
        if !drives.isEmpty { text += ", vers " + drives.joined(separator: " et ") }
        return text + "."
    }
}

/// What stops the backup, if anything, and the button.
private struct ActionBar: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        let blockers = ingest.blockers
        let allSaved = ingest.plan.toCopy.isEmpty && ingest.plan.alreadyCopied > 0
        HStack(spacing: 16) {
            if let first = blockers.first {
                Label(first, systemImage: allSaved ? "checkmark.seal" : "exclamationmark.circle")
                    .font(TypeScale.meta)
                    .foregroundStyle(allSaved ? Palette.accentInk : Palette.late)
                    .help(blockers.joined(separator: "\n"))
            } else if let warning = ingest.warnings.first {
                // It does not hold the button back; it is said before ⌘↩ all
                // the same, because the card is formatted on this page's word.
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.late)
                    .help(ingest.warnings.joined(separator: "\n"))
            } else {
                Text(detail)
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkFaint)
            }
            Spacer()
            Button {
                ingest.start()
            } label: {
                Label("Sauvegarder", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.accentFilled)
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!ingest.canStart)
            .help("⌘↩")
        }
        .padding(.horizontal, Page.gutter)
        .padding(.vertical, 14)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    /// One plain sentence: what will happen besides the copy.
    private var detail: String {
        var text = "Chaque copie est relue et vérifiée"
        if ingest.settings.ejectWhenDone { text += ", les cartes sont éjectées à la fin" }
        if ingest.plan.alreadyCopied > 0 {
            text += ". \(Format.count(ingest.plan.alreadyCopied, "prise déjà sauvegardée", "prises déjà sauvegardées")), ignorée\(ingest.plan.alreadyCopied > 1 ? "s" : "")"
        }
        return text + "."
    }
}
