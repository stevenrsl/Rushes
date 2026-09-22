import SwiftUI

/// What changes rarely, in tabs as Cairn's settings are.
struct SettingsView: View {
    var body: some View {
        TabView {
            NamingSettings()
                .tabItem { Label("Rangement", systemImage: "folder") }
            CameraSettings()
                .tabItem { Label("Caméras", systemImage: "camera") }
            CopySettings()
                .tabItem { Label("Copie", systemImage: "externaldrive") }
        }
        .frame(width: 540)
        .tint(Palette.accentLine)
    }
}

private struct Help: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(TypeScale.meta)
            .foregroundStyle(Palette.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NamingSettings: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        Form {
            Section {
                Stepper(value: $ingest.settings.dayCutoffHour, in: 0...10) {
                    Text(ingest.settings.dayCutoffHour == 0
                        ? "Le jour change à minuit"
                        : "Une prise avant \(ingest.settings.dayCutoffHour) h compte pour la veille")
                }
                Help("Un tournage qui finit à 2 h du matin garde la date du jour où il a commencé.")
            }

            Section {
                LabeledContent("Dossier du tournage") {
                    HStack(spacing: 8) {
                        TextField("", text: $ingest.settings.folderPattern, prompt: Text("dans la destination"))
                            .font(TypeScale.code)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                        Menu {
                            ForEach(ShootFolderPresets.patterns, id: \.self) { pattern in
                                Button(pattern.isEmpty ? "Directement dans la destination" : pattern) {
                                    ingest.settings.folderPattern = pattern
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Modèles de dossier")
                    }
                }
                Help("Mêmes jetons que le nom, « / » pour un sous-dossier : {CLIENT}/{YYMMDD}_{PROJET} range chaque client à part. Vide : directement dans la destination.")
            }

            Section {
                Picker("Dans le dossier du tournage", selection: layoutPreset) {
                    ForEach(FolderPreset.allCases) { Text($0.title).tag(Optional($0)) }
                    Text("Personnalisé").tag(FolderPreset?.none)
                }
                ForEach(FolderLayout.roles, id: \.self) { role in
                    LabeledContent(Self.title(of: role)) {
                        TextField("", text: $ingest.settings.layout[role], prompt: Text("dossier du tournage"))
                            .font(TypeScale.code)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                    }
                }
                Help((FolderPreset.matching(ingest.settings.layout)?.detail ?? "Un dossier par type, avec les jetons du nom : {CAM} pour la lettre de la carte, {HHMMSS} pour l'heure.") + " Les métadonnées suivent leur fichier. Vide : dans le dossier du tournage.")
                Text(example)
                    .font(TypeScale.code)
                    .foregroundStyle(Palette.accentInk)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Section {
                Picker("Chiffres", selection: $ingest.settings.padding) {
                    ForEach(3...6, id: \.self) { n in
                        Text(String(repeating: "0", count: n - 1) + "1").tag(n)
                    }
                }
                Toggle("Un seul compteur pour les photos et les vidéos", isOn: $ingest.settings.sharedCounter)
                Help("Les numéros suivent l'ordre des prises, toutes cartes confondues, et reprennent après le plus haut déjà présent sur les disques pour le même jour, client et projet. Avec {CAM} dans le nom, chaque caméra compte de son côté.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }

    /// The preset the six folders match, or none when one was typed.
    private var layoutPreset: Binding<FolderPreset?> {
        Binding(
            get: { FolderPreset.matching(ingest.settings.layout) },
            set: { if let preset = $0 { ingest.settings.layout = preset.layout } }
        )
    }

    private static func title(of role: FileRole) -> String {
        switch role {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .video: "Vidéo"
        case .proxy: "Proxy"
        case .audio: "Son"
        case .sidecar, .thumbnail: ""
        }
    }

    /// Where the A camera's first clip would land, from the drive's root.
    private var example: String {
        let settings = ingest.settings
        let values = NameValues(
            day: ShootDay(date: .now, cutoffHour: settings.dayCutoffHour),
            time: "213000",
            initials: Sanitize.code(settings.initials).isEmpty ? "XX" : Sanitize.code(settings.initials),
            client: Sanitize.field(settings.client).isEmpty ? "Client" : Sanitize.field(settings.client),
            project: Sanitize.field(settings.project).isEmpty ? "Projet" : Sanitize.field(settings.project),
            camera: "A",
            original: "C0001",
            type: "VIDEO",
            number: 1,
            padding: settings.padding
        )
        let path = [
            NameTemplate(settings.folderPattern).renderPath(values),
            settings.layout.folder(for: .video, anchor: .video, values: values),
            NameTemplate(settings.namePattern).render(values) + ".MP4",
        ].filter { !$0.isEmpty }
        return path.joined(separator: "/")
    }
}

/// The letters chosen for each body, to rename or forget.
private struct CameraSettings: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        Form {
            Section {
                if ingest.settings.cameras.isEmpty {
                    Text("Aucune caméra retenue.")
                        .foregroundStyle(Palette.inkSoft)
                }
                ForEach(ingest.settings.cameras) { camera in
                    HStack(spacing: 12) {
                        CameraLetterField(label: camera.label) { ingest.relabelCamera(camera, $0) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name)
                                .font(TypeScale.ui)
                                .foregroundStyle(Palette.ink)
                            if camera.id != camera.name {
                                Text("n° " + String(camera.id.dropFirst(camera.name.count + 2)))
                                    .font(TypeScale.micro)
                                    .foregroundStyle(Palette.inkFaint)
                            }
                        }
                        Spacer()
                        Button("Oublier") { ingest.forgetCamera(camera) }
                            .buttonStyle(.accentLink)
                            .font(TypeScale.meta)
                    }
                }
            } footer: {
                Help("Tape une lettre sur la pastille d'une carte : ce boîtier la retrouve tout seul ensuite. Il est reconnu à son numéro de série quand l'appareil l'écrit, sinon à son modèle. Pour les cartes vidéo Sony, le XML du clip le dit.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}

private struct CopySettings: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        Form {
            Section {
                LabeledContent("Types de fichiers") {
                    Button("Rétablir les choix par défaut") { ingest.settings.kindChoices = [:] }
                        .disabled(ingest.settings.kindChoices.isEmpty)
                }
                Help("Les types se cochent dans le bloc Fichiers de la page, et le choix est retenu. Par défaut tout est copié sauf les proxys, les vignettes de l'appareil et les XML. Une métadonnée prend le nom de son fichier : C0001M01.XML devient …_0001M01.XML à côté de …_0001.MP4.")
            }

            Section {
                Toggle("Ignorer ce qui est déjà sauvegardé sur chaque disque", isOn: $ingest.settings.skipAlreadyCopied)
                Toggle("Éjecter les cartes quand tout est vérifié", isOn: $ingest.settings.ejectWhenDone)
                Help("Rushes ne modifie ni n'efface jamais rien sur une carte, et ne remplace jamais un fichier sur un disque. Formate tes cartes dans l'appareil, une fois la sauvegarde vérifiée.")
            }

            Section {
                Picker("Apparence", selection: $ingest.settings.appearance) {
                    ForEach(IngestSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}
