import AppKit
import Observation
import SwiftUI

/// The state of "Vérifier un disque": a folder chosen, read back, answered.
@MainActor
@Observable
final class AuditModel {
    enum Phase {
        case idle
        case running(URL)
        case finished(Audit.Report)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = Audit.Progress()
    private let cancelFlag = CancelFlag()
    private var activity: NSObjectProtocol?

    var isRunning: Bool { if case .running = phase { true } else { false } }

    init() {}

    /// A page in a given state, to be looked at without a drive to read.
    init(showing phase: Phase, progress: Audit.Progress = .init()) {
        self.phase = phase
        self.progress = progress
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Vérifier"
        panel.message = "Choisis un disque entier, ou le dossier d'un tournage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
    }

    func start(_ root: URL) {
        guard !isRunning else { return }
        cancelFlag.reset()
        progress = Audit.Progress()
        phase = .running(root)
        // A drive of a year's shooting is read end to end: hours, not minutes.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Vérification d'un disque"
        )
        let flag = cancelFlag
        Task.detached(priority: .userInitiated) {
            let report = Audit.run(root, isCancelled: { flag.isSet }) { state in
                Task { @MainActor in self.advance(state) }
            }
            await MainActor.run { self.finish(report) }
        }
    }

    func cancel() { cancelFlag.set() }

    func reset() { phase = .idle }

    private func advance(_ state: Audit.Progress) {
        guard isRunning else { return }
        progress = state
    }

    private func finish(_ report: Audit.Report) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        phase = .finished(report)
    }
}

/// A page of its own, in the window of the same name: it can run while the
/// main window prepares tonight's cards.
struct AuditView: View {
    @Environment(AuditModel.self) private var audit

    /// Off for drawing the page to an image, which a scroll view does not do.
    var scrolls = true

    var body: some View {
        if scrolls {
            PageScroll { page }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pageGround()
                .frame(minWidth: 640, minHeight: 480)
        } else {
            page
        }
    }

    private var page: some View {
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
                content.padding(.top, 34)
            }
            .padding(.top, Page.top)
            .padding(.bottom, 40)
    }

    private var trail: [String] {
        switch audit.phase {
        case .idle: ["Vérifier un disque"]
        case .running(let root): ["Vérifier un disque", root.lastPathComponent]
        case .finished(let report): ["Vérifier un disque", report.root.lastPathComponent]
        }
    }

    private var title: String {
        switch audit.phase {
        case .idle: "Relire une archive"
        case .running: "Relecture en cours"
        case .finished(let report):
            if report.records == 0 { "Aucun relevé ici" }
            else if report.cancelled { "Vérification interrompue" }
            else if report.problems.isEmpty { "Tout est intact" }
            else { "\(Format.count(report.problems.count, "fichier")) à regarder" }
        }
    }

    private var sentence: String {
        switch audit.phase {
        case .idle:
            return "Chaque fichier que Rushes a copié est relu sur le disque et comparé à son relevé. Rien n'est écrit, déplacé ni réparé : Rushes ne fait que lire."
        case .running:
            return "Le Mac ne se mettra pas en veille. La relecture peut durer : c'est la vitesse du disque qui compte."
        case .finished(let report):
            if report.records == 0 {
                return "Ce dossier ne contient aucun dossier _RUSHES : il n'a pas été rempli par Rushes, ou ses relevés ont été enlevés."
            }
            let read = "\(Format.count(report.checked, "fichier")) relus, \(Format.bytes(report.bytes))"
            if report.cancelled { return read + " avant l'arrêt." }
            if report.problems.isEmpty {
                return read + ". Chacun se lit exactement comme le jour où il a été copié."
            }
            return read + ". \(Format.number(report.intact)) se lisent exactement comme le jour de la copie, pas ceux-ci."
        }
    }

    @ViewBuilder private var content: some View {
        switch audit.phase {
        case .idle:
            Button {
                audit.choose()
            } label: {
                Label("Choisir un disque ou un dossier…", systemImage: "externaldrive")
            }
            .buttonStyle(.accentFilled)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

        case .running:
            let p = audit.progress
            VStack(alignment: .leading, spacing: 14) {
                Text("\(Int((p.fraction * 100).rounded(.down))) %")
                    .font(TypeScale.figure)
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
                Button("Interrompre") { audit.cancel() }
                    .buttonStyle(.accentLink)
                    .font(TypeScale.meta)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 4)
            }

        case .finished(let report):
            VStack(alignment: .leading, spacing: 0) {
                if !report.problems.isEmpty {
                    problems(report, .missing, "Manquants")
                    problems(report, .resized(0), "Taille changée")
                    problems(report, .changed(""), "Contenu changé")
                    problems(report, .unreadable(""), "Illisibles")
                }
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: 20) {
                    Button {
                        audit.choose()
                    } label: {
                        Label("Vérifier un autre", systemImage: "externaldrive")
                    }
                    .buttonStyle(.accentFilled)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([report.root])
                    }
                    .buttonStyle(.accentLink)
                    .font(TypeScale.meta)
                }
                .padding(.top, 24)
                if !report.problems.isEmpty {
                    Text("Le nom d'origine et la carte de chaque fichier sont dans son relevé : c'est là qu'il faut aller le rechercher, sur l'autre disque ou sur la carte si elle n'a pas été formatée.")
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
        }
    }

    /// One family of problems, as a section of the sheet.
    @ViewBuilder private func problems(_ report: Audit.Report, _ kind: Audit.Problem.Kind, _ title: String) -> some View {
        let list = report.problems.filter { same($0.kind, kind) }
        if !list.isEmpty {
            PageSection(title: title) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.item.path)
                                .font(TypeScale.code)
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                            Text("\(problem.sentence) Sur la carte « \(problem.item.volume) », c'était \(problem.item.original).")
                                .font(TypeScale.meta)
                                .foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func same(_ a: Audit.Problem.Kind, _ b: Audit.Problem.Kind) -> Bool {
        switch (a, b) {
        case (.missing, .missing), (.resized, .resized), (.changed, .changed), (.unreadable, .unreadable): true
        default: false
        }
    }
}
