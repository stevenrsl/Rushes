import AppKit
import SwiftUI

/// While the backup runs: one figure, in serif, and the reassurance that the
/// Mac will not sleep.
struct CopyingView: View {
    @Environment(Ingest.self) private var ingest
    @State private var confirmCancel = false

    var body: some View {
        let p = ingest.progress
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PageTrail(steps: [Format.sentenceDay(.now), "Sauvegarde"])
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(p.verifying ? "Vérification des copies" : "Copie depuis la carte")
                        .font(TypeScale.display)
                        .foregroundStyle(Palette.ink)
                    Text("Le Mac ne se mettra pas en veille. Laisse-le ouvert et branché : une notification sonnera à la fin.")
                        .font(TypeScale.aim)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // On the ground, as the rest of the page: the figure is enough.
                VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Int((p.fraction * 100).rounded(.down))) %")
                                .font(TypeScale.figure)
                                .foregroundStyle(Palette.ink)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                if ingest.speed > 0 {
                                    Text(Format.speed(ingest.speed))
                                        .font(TypeScale.strong)
                                        .foregroundStyle(Palette.inkSoft)
                                }
                                if let remaining = ingest.remaining, p.fraction > 0.01 {
                                    Text("reste \(Format.duration(remaining))")
                                        .font(TypeScale.meta)
                                        .foregroundStyle(Palette.inkFaint)
                                }
                            }
                            .monospacedDigit()
                        }
                        Bar(fraction: p.fraction, height: 8)
                        HStack {
                            Text("\(Format.number(p.filesDone)) / \(Format.count(p.filesTotal, "fichier"))")
                                .font(TypeScale.meta)
                                .foregroundStyle(Palette.inkSoft)
                                .monospacedDigit()
                            Spacer(minLength: 16)
                            Text(p.current)
                                .font(TypeScale.code)
                                .foregroundStyle(Palette.inkFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                }
                .padding(.top, 34)

                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let still = context.date.timeIntervalSince(ingest.lastMoved)
                    if still >= 20, !ingest.progress.quiet {
                        Text("Plus rien n'avance depuis \(still < 60 ? "\(Int(still)) s" : Format.roughDuration(still)) : le lecteur ou la carte peine peut-être.")
                            .font(TypeScale.meta)
                            .foregroundStyle(Palette.late)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                }

                Button("Interrompre…") { confirmCancel = true }
                    .buttonStyle(.accentLink)
                    .font(TypeScale.meta)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 18)
            }
            .padding(.top, Page.top)
            .padding(.bottom, 40)
        }
        .confirmationDialog("Interrompre la sauvegarde ?", isPresented: $confirmCancel) {
            Button("Interrompre", role: .destructive) { ingest.cancel() }
            Button("Continuer", role: .cancel) {}
        } message: {
            Text("Les fichiers déjà copiés et vérifiés restent sur les disques et seront reconnus la prochaine fois. Le fichier en cours est effacé des disques, jamais de la carte.")
        }
    }
}

/// The end: checked, how much, and what to do with the cards.
struct DoneView: View {
    @Environment(Ingest.self) private var ingest
    let report: BackupReport
    /// The card whose format is being asked, until it is confirmed.
    @State private var toFormat: Ingest.Card?

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PageTrail(steps: [Format.sentenceDay(.now), "Sauvegarde"])
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(tint)
                        Text(title)
                            .font(TypeScale.display)
                            .foregroundStyle(Palette.ink)
                    }
                    Text(sentence)
                        .font(TypeScale.aim)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    PageSection(title: "Bilan") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            fact("Fichiers", Format.number(report.filesCopied))
                            fact("Volume", Format.bytes(report.bytesCopied))
                            fact("Disques", ingest.backupDriveNames.joined(separator: ", "))
                            fact("Durée", Format.duration(report.finished.timeIntervalSince(report.started)))
                            if let message = ingest.ejectMessage {
                                fact("Cartes", message)
                            }
                            ForEach(Array(ingest.formatMessages.enumerated()), id: \.offset) { _, message in
                                fact("Formatage", message)
                            }
                        }
                    }

                    if !ingest.verdicts.isEmpty {
                        PageSection(title: "Cartes") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(ingest.verdicts) { verdict in
                                    let card = ingest.formatableCards.first { $0.id == verdict.cardID }
                                    VerdictRow(
                                        verdict: verdict,
                                        canFormat: card != nil,
                                        formatting: ingest.formatting == verdict.cardID,
                                        busy: ingest.formatting != nil
                                    ) {
                                        toFormat = card
                                    }
                                }
                            }
                        }
                    }

                    if report.stopped != nil || !report.failures.isEmpty {
                        PageSection(title: "Pas copiés") {
                            VStack(alignment: .leading, spacing: 10) {
                                if let stopped = report.stopped {
                                    Text(stopped)
                                        .font(TypeScale.meta)
                                        .foregroundStyle(Palette.alert)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(report.failures, id: \.self) { failure in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(failure.file).font(TypeScale.code).foregroundStyle(Palette.ink)
                                        Text(failure.message).font(TypeScale.meta).foregroundStyle(Palette.inkSoft)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if ingest.settings.upload.isReady {
                        PageSection(title: "Envoi") { UploadBlock() }
                    }

                    Rectangle().fill(Palette.hairline).frame(height: 1)

                    HStack(spacing: 20) {
                        Button {
                            ingest.reset()
                        } label: {
                            Label(report.succeeded ? "Nouvelle sauvegarde" : "Reprendre", systemImage: report.succeeded ? "plus" : "arrow.clockwise")
                        }
                        .buttonStyle(.accentFilled)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(ingest.isUploading || ingest.formatting != nil)
                        .help(ingest.isUploading ? "Attends la fin de l'envoi, ou interromps-le" : "")

                        if !report.folders.isEmpty {
                            Button("Afficher dans le Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(report.folders)
                            }
                            .buttonStyle(.accentLink)
                            .font(TypeScale.meta)
                        }
                        if let first = ingest.reportURLs.first {
                            Button("Ouvrir le rapport") {
                                NSWorkspace.shared.open(first)
                            }
                            .buttonStyle(.accentLink)
                            .font(TypeScale.meta)
                            .help("Une page à garder ou à envoyer, dans _RUSHES à côté du relevé")
                        }
                        if !ingest.ejected, ingest.ejectableCards.contains(where: \.isVolume) {
                            Button("Éjecter les cartes") {
                                Task { await ingest.ejectCards() }
                            }
                            .buttonStyle(.accentLink)
                            .font(TypeScale.meta)
                        }
                    }
                    .padding(.top, 24)

                    if !report.succeeded {
                        Text("Reprendre relit les cartes : ce qui a été copié et vérifié est reconnu, seul le reste sera copié.")
                            .font(TypeScale.meta)
                            .foregroundStyle(Palette.inkFaint)
                            .padding(.top, 10)
                    }
                }
                .padding(.top, 34)
            }
            .padding(.top, Page.top)
            .padding(.bottom, 40)
        }
        .confirmationDialog(
            "Formater « \(toFormat?.name ?? "") » ?",
            isPresented: Binding(get: { toFormat != nil }, set: { if !$0 { toFormat = nil } }),
            presenting: toFormat
        ) { card in
            Button("Formater « \(card.name) »", role: .destructive) {
                Task { await ingest.format(card) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Tout ce qui est sur la carte est effacé, sans retour. Sa sauvegarde a été relue sur chaque disque. Elle garde son nom et son format, puis elle est éjectée.")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(TypeScale.meta)
                .foregroundStyle(Palette.inkFaint)
            Text(value)
                .font(TypeScale.ui)
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
    }

    private var icon: String {
        if report.succeeded { return "checkmark.seal.fill" }
        if report.cancelled { return "pause.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        report.succeeded ? Palette.accentInk : report.cancelled ? Palette.late : Palette.alert
    }

    private var title: String {
        if report.succeeded { return "Sauvegarde vérifiée" }
        if report.cancelled { return "Sauvegarde interrompue" }
        return "Sauvegarde incomplète"
    }

    private var sentence: String {
        if report.succeeded {
            // The cards have the last word below, one by one: this line says
            // only what was done, and never "tu peux formater" in general.
            var text = "Chaque copie a été relue sur le disque et correspond à ce qui a été lu sur la carte."
            let held = ingest.verdicts.filter { $0.level != .safe }
            text += held.isEmpty ? " Tu peux aller dormir." : " Regarde les cartes avant de les formater."
            return text
        }
        if report.cancelled {
            return "\(Format.count(report.filesCopied, "fichier")) copiés et vérifiés avant l'arrêt ; ils seront reconnus à la reprise."
        }
        if report.failures.isEmpty, report.stopped == nil, !report.unflushed.isEmpty {
            return "Tout a été copié et relu, mais \(report.unflushed.map { "« \($0) »" }.joined(separator: ", ")) n'a pas confirmé l'avoir écrit jusqu'au bout. Ne formate pas ces cartes ce soir."
        }
        return "Ce qui a été copié est vérifié. Le reste est listé ci-dessous, rien n'a été remplacé."
    }
}

/// One card and what it may do next. The colours are the app's signals: the
/// deep forest for what is done, peat for what wants a look, sea thrift for
/// what must not be formatted.
private struct VerdictRow: View {
    let verdict: CardVerdict
    var canFormat = false
    var formatting = false
    var busy = false
    var format: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // One width for every icon, so the names and sentences line up.
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verdict.cardName)
                        .font(TypeScale.ui)
                        .foregroundStyle(Palette.ink)
                    StatusPill(text: verdict.title, ink: tint, fill: wash)
                }
                Text(verdict.sentence)
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canFormat || formatting {
                Spacer(minLength: 16)
                if formatting {
                    ProgressView().controlSize(.small)
                    Text("Formatage…")
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkSoft)
                } else {
                    Button("Formater…", action: format)
                        .buttonStyle(.accentLink)
                        .font(TypeScale.meta)
                        .disabled(busy)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(verdict.cardName), \(verdict.title). \(verdict.sentence)")
    }

    private var icon: String {
        switch verdict.level {
        case .safe: "checkmark.seal"
        case .check: "eye"
        case .hold: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch verdict.level {
        case .safe: Palette.accentInk
        case .check: Palette.late
        case .hold: Palette.alert
        }
    }

    private var wash: Color {
        switch verdict.level {
        case .safe: Palette.accentSoft
        case .check: Palette.lateSoft
        case .hold: Palette.alertSoft
        }
    }
}

/// The copy sent elsewhere once the drives are done: a button, a bar, then
/// what came of it. The drives are the backup; this line never says otherwise.
private struct UploadBlock: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        let name = ingest.settings.upload.name
        VStack(alignment: .leading, spacing: 10) {
            switch ingest.uploadPhase {
            case .idle:
                HStack(spacing: 16) {
                    Text("Une copie de ce qui vient d'être vérifié peut partir vers \(name).")
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Envoyer") { ingest.startUpload() }
                        .buttonStyle(.accentLink)
                        .font(TypeScale.meta)
                        .disabled(!ingest.canUpload)
                }
            case .sending:
                let p = ingest.uploadProgress
                HStack(alignment: .firstTextBaseline) {
                    Text("Envoi vers \(name) · \(Int((p.fraction * 100).rounded(.down))) %")
                        .font(TypeScale.ui)
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Spacer()
                    Button("Interrompre") { ingest.cancelUpload() }
                        .buttonStyle(.accentLink)
                        .font(TypeScale.meta)
                }
                Bar(fraction: p.fraction)
                HStack {
                    Text("\(Format.number(p.filesDone)) / \(Format.count(p.filesTotal, "fichier"))")
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkSoft)
                        .monospacedDigit()
                    Spacer(minLength: 16)
                    Text(p.current)
                        .font(TypeScale.code)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .finished(let report):
                Text(sentence(report, name: name))
                    .font(TypeScale.meta)
                    .foregroundStyle(report.succeeded ? Palette.accentInk : report.cancelled ? Palette.late : Palette.alert)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.failures, id: \.self) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.file).font(TypeScale.code).foregroundStyle(Palette.ink)
                        Text(failure.message).font(TypeScale.meta).foregroundStyle(Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !report.succeeded {
                    Button("Envoyer à nouveau") { ingest.startUpload() }
                        .buttonStyle(.accentLink)
                        .font(TypeScale.meta)
                        .disabled(!ingest.canUpload)
                }
            }
        }
    }

    private func sentence(_ report: UploadReport, name: String) -> String {
        let done = report.sent + report.alreadyThere
        if report.succeeded {
            var text = "\(Format.count(done, "fichier")) sur \(name)"
            if report.alreadyThere > 0, report.sent > 0 {
                text += ", dont \(Format.number(report.alreadyThere)) déjà là"
            }
            return text + "."
        }
        if let stopped = report.stopped {
            return "\(stopped) Les disques, eux, sont complets."
        }
        if report.cancelled {
            return "Envoi interrompu après \(Format.count(report.sent, "fichier")). Envoyer à nouveau reprend là où il s'est arrêté."
        }
        return "\(Format.count(report.failures.count, "fichier")) n'\(report.failures.count > 1 ? "ont" : "a") pas pu partir vers \(name). Les disques, eux, sont complets."
    }
}
