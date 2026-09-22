import AppKit
import SwiftUI

/// The column on the left, as Cairn's: the cards found, each with its camera
/// and its letter, and at the foot the way to add a folder by hand.
struct CardsColumn: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        List {
            Section("Cartes") {
                if ingest.cards.isEmpty {
                    EmptyCards()
                }
                ForEach(ingest.cards) { card in
                    CardRow(card: card)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.sidebar)
        // Opaque, as in Cairn and Journal: no wallpaper through the column.
        .scrollContentBackground(.hidden)
        .background(Palette.groundSunk)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Footer().background(Palette.groundSunk)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
    }
}

private struct EmptyCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Insère une carte")
                    .font(TypeScale.ui)
                    .foregroundStyle(Palette.ink)
            } icon: {
                Image(systemName: "sdcard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.inkSoft)
            }
            Text("Elle apparaît ici toute seule, quelle que soit la marque de l'appareil.")
                .font(TypeScale.meta)
                .foregroundStyle(Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct CardRow: View {
    @Environment(Ingest.self) private var ingest
    let card: Ingest.Card

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ForestCheckbox(checked: card.included) { ingest.setIncluded(card, !card.included) }
                .padding(.top, 2)
                .disabled(ingest.isCopying)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.scan?.cameraName ?? card.name)
                    .font(TypeScale.ui)
                    .foregroundStyle(card.included ? Palette.ink : Palette.inkSoft)
                    .lineLimit(1)

                switch card.state {
                case .scanning(let message):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(message)
                            .font(TypeScale.meta)
                            .foregroundStyle(Palette.inkSoft)
                            .monospacedDigit()
                    }
                case .failed(let message):
                    Text(message)
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.alert)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready(let scan):
                    Text(counts(scan))
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkSoft)
                    Text(details(scan))
                        .font(TypeScale.micro)
                        .foregroundStyle(Palette.inkFaint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            CameraLetterField(label: card.cameraLabel) { ingest.setLabel(card, $0) }
                .disabled(ingest.isCopying)
                .help(ingest.isRemembered(card)
                      ? "Lettre retenue pour ce boîtier. Tape une autre lettre pour la changer."
                      : "La lettre de cette caméra, {CAM} dans le nom. Tape A, D, B2… : ce boîtier la retrouvera tout seul.")
        }
        .padding(.vertical, 5)
        .help(card.name)
        .opacity(card.included ? 1 : 0.6)
        .contextMenu {
            Button("Relire la carte") { ingest.rescan(card) }
            if card.isVolume {
                Button("Éjecter") { Task { try? await VolumeWatcher.eject(card.url) } }
            }
            Button("Retirer de la liste") { ingest.remove(card) }
        }
    }

    private func counts(_ scan: CardScan) -> String {
        var parts: [String] = []
        if scan.photoCount > 0 { parts.append(Format.count(scan.photoCount, "photo")) }
        if scan.videoCount > 0 { parts.append(Format.count(scan.videoCount, "vidéo")) }
        if scan.audioCount > 0 { parts.append(Format.count(scan.audioCount, "son")) }
        return parts.isEmpty ? "Aucun fichier d'appareil" : parts.joined(separator: ", ")
    }

    /// Its size and when it was shot. The card's own name, often NO NAME or
    /// Untitled, is in the tooltip.
    private func details(_ scan: CardScan) -> String {
        var line = Format.bytes(scan.totalSize)
        if let first = scan.firstDate, let last = scan.lastDate {
            line += " · \(Format.time(first)) → \(Format.time(last))"
        }
        return line
    }
}

/// Cairn's footer: a hairline, then a quiet line that acts.
private struct Footer: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Button {
                chooseFolder()
            } label: {
                Label {
                    Text("Ajouter un dossier…")
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkSoft)
                } icon: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ingest.isCopying)
            .help("Une carte que le Mac ne reconnaît pas, ou un appareil branché en stockage de masse")
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        panel.message = "Choisis la racine d'une carte, ou un dossier de fichiers d'appareil."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK {
            for url in panel.urls { ingest.addFolder(url) }
        }
    }
}
