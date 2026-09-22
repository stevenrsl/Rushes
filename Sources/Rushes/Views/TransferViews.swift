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
                    Text("Le Mac ne se mettra pas en veille. Tu peux éteindre l'écran : une notification sonnera à la fin.")
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
                            fact("Disques", ingest.onlineDrives.map(\.name).joined(separator: ", "))
                            fact("Durée", Format.duration(report.finished.timeIntervalSince(report.started)))
                            if let message = ingest.ejectMessage {
                                fact("Cartes", message)
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

                        if !report.folders.isEmpty {
                            Button("Afficher dans le Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(report.folders)
                            }
                            .buttonStyle(.accentLink)
                            .font(TypeScale.meta)
                        }
                        if !ingest.ejected, ingest.readyCards.contains(where: \.isVolume) {
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
            return "Chaque copie a été relue et correspond à la carte, octet pour octet. Tu peux aller dormir."
        }
        if report.cancelled {
            return "\(Format.count(report.filesCopied, "fichier")) copiés et vérifiés avant l'arrêt ; ils seront reconnus à la reprise."
        }
        return "Ce qui a été copié est vérifié. Le reste est listé ci-dessous, rien n'a été remplacé."
    }
}
