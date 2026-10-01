import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Aide menu: describe a card, report a problem, write. What a beta
/// tester needs to tell Steven what their camera did (2026-10-01).
struct HelpCommands: Commands {
    let ingest: Ingest

    static let issues = URL(string: "https://github.com/stevenrsl/Rushes/issues/new/choose")!
    static let address = "rushes@stevenrsl.eu"

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Décrire une carte…") { CardDescription.run(settings: ingest.settings) }
            Divider()
            Button("Signaler un problème…") { NSWorkspace.shared.open(Self.issues) }
            Button("Écrire à \(Self.address)") {
                var mail = URLComponents()
                mail.scheme = "mailto"
                mail.path = Self.address
                mail.queryItems = [URLQueryItem(name: "subject", value: "Rushes \(Self.version)")]
                if let url = mail.url { NSWorkspace.shared.open(url) }
            }
        }
    }

    static var version: String {
        Bundle.main.version
    }
}

/// Aide › Décrire une carte…: the card is chosen, read as a backup would read
/// it, and its `CardDiagnostic` saved where the person says, never on the card.
@MainActor
enum CardDescription {
    static func run(settings: IngestSettings) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.directoryURL = URL(fileURLWithPath: "/Volumes")
        open.message = "Choisis la carte à décrire. Rushes la lit seulement, comme pour une sauvegarde."
        open.prompt = "Décrire"
        guard open.runModal() == .OK, let card = open.url else { return }

        Task {
            let made = await Task.detached(priority: .userInitiated) {
                Result { try CardDiagnostic.make(card, settings: settings) }
            }.value
            switch made {
            case .failure(let error):
                tell("Cette carte ne se lit pas", error.localizedDescription)
            case .success(let diagnostic):
                save(diagnostic, from: card)
            }
        }
    }

    private static func save(_ diagnostic: CardDiagnostic, from card: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = diagnostic.suggestedFileName
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "Joins ce fichier à ton retour. Il ne contient aucune image, ni le nom de la carte, ni rien de ce que tu as tapé dans Rushes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A card is only ever read, even to describe it. A folder on the
        // Mac's own disk described as a card is not a card.
        if let cardVolume = VolumeWatcher.volume(of: card), cardVolume.path != "/",
           VolumeWatcher.volume(of: url.deletingLastPathComponent()) == cardVolume {
            tell("Choisis un autre endroit que la carte", "Rushes n'écrit jamais sur une carte, même pour la décrire.")
            return save(diagnostic, from: card)
        }
        do {
            try diagnostic.encoded().write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            tell("Le fichier n'a pas pu être écrit", error.localizedDescription)
        }
    }

    private static func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
