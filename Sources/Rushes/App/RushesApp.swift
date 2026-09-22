import AppKit
import SwiftUI

@main
struct RushesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var ingest = Ingest()

    var body: some Scene {
        Window("Rushes", id: "main") {
            RootView()
                .environment(ingest)
                .preferredColorScheme(ingest.settings.appearance.scheme)
                .onAppear { delegate.ingest = ingest }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(ingest)
                .preferredColorScheme(ingest.settings.appearance.scheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var ingest: Ingest?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(MainActor.assumeIsolated { ingest?.isCopying } ?? false)
    }

    /// Quitting in the middle of a backup is asked, not refused: the cable
    /// may need to come out. What was checked is kept either way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let copying = MainActor.assumeIsolated { ingest?.isCopying } ?? false
        guard copying else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Une sauvegarde est en cours"
        alert.informativeText = "Quitter l'interrompt. Les fichiers déjà vérifiés restent sur les disques et seront reconnus la prochaine fois."
        alert.addButton(withTitle: "Continuer la sauvegarde")
        alert.addButton(withTitle: "Quitter")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

extension IngestSettings.Appearance {
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
