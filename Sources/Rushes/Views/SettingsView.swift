import AppKit
import SwiftUI

/// What changes rarely, in tabs as Cairn's settings are.
struct SettingsView: View {
    enum Tab: String { case naming, cameras, copy, upload, appearance }

    /// Kept so the preparation page can open the window on the tab it means.
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = Tab.naming

    var body: some View {
        TabView(selection: $tab) {
            NamingSettings()
                .tabItem { Label("Rangement", systemImage: "folder") }
                .tag(Tab.naming)
            CameraSettings()
                .tabItem { Label("Caméras", systemImage: "camera") }
                .tag(Tab.cameras)
            CopySettings()
                .tabItem { Label("Copie", systemImage: "externaldrive") }
                .tag(Tab.copy)
            UploadSettings()
                .tabItem { Label("Envoi", systemImage: "icloud.and.arrow.up") }
                .tag(Tab.upload)
            AppearanceSettings()
                .tabItem { Label("Apparence", systemImage: "paintpalette") }
                .tag(Tab.appearance)
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
                Help("Une prise n'est ignorée que si le relevé la liste et qu'elle est encore là, à la bonne taille, sur chaque disque : un fichier trié, déplacé ou disparu est recopié. Rushes ne remplace jamais un fichier sur un disque.")
            }

            Section {
                Picker("À la fin, les cartes formatables", selection: $ingest.settings.whenDone) {
                    ForEach(IngestSettings.WhenDone.allCases) { Text($0.title).tag($0) }
                }
                Help(whenDoneHelp)
            }

            Section {
                Toggle("Écrire un ASC MHL dans chaque tournage", isOn: $ingest.settings.writeMHL)
                Help("Le format de liste de hashs que lisent les DIT, Silverstack et les post-productions. Chaque sauvegarde ajoute une génération dans un dossier ascmhl, à côté des fichiers, sans jamais réécrire les précédentes. Le relevé de Rushes, lui, est toujours écrit.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }

    private var whenDoneHelp: String {
        switch ingest.settings.whenDone {
        case .eject:
            "Une carte dont tout est sur chaque disque est éjectée, prête à retourner dans l'appareil pour y être formatée. Une carte « ne pas formater » ne l'est jamais."
        case .keep:
            "Les cartes restent dans le lecteur. La page de fin propose de les éjecter."
        case .offerFormat:
            "La page de fin propose de formater chaque carte « formatable », une par une, après confirmation, puis l'éjecte. Rushes vérifie d'abord que c'est bien la carte sauvegardée. Une carte « à vérifier » ou « ne pas formater » ne l'est jamais. Si l'appareil demande ensuite à recréer ses dossiers ou sa base d'images, laisse-le faire."
        }
    }
}

/// Where a copy of the night goes once the drives are verified.
private struct UploadSettings: View {
    @Environment(Ingest.self) private var ingest
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var ingest = ingest
        let target = ingest.settings.upload
        Form {
            Section {
                Picker("Envoyer une copie vers", selection: $ingest.settings.upload.kind) {
                    ForEach(UploadTarget.Kind.allCases) { Text($0.title).tag($0) }
                }
                Help("Une fois la sauvegarde vérifiée sur les disques, Rushes peut en envoyer une copie ailleurs. Elle est lue sur le premier disque, jamais sur la carte, et le verdict des cartes ne l'attend pas : les disques restent la sauvegarde.")
            }

            switch target.kind {
            case .none:
                EmptyView()
            case .folder:
                Section {
                    LabeledContent("Dossier") {
                        HStack(spacing: 10) {
                            Text(target.folder.isEmpty ? "Aucun" : target.folder)
                                .font(TypeScale.code)
                                .foregroundStyle(target.folder.isEmpty ? Palette.inkFaint : Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choisir…") { chooseFolder() }
                        }
                    }
                    Help("Le dossier qu'iCloud Drive, Dropbox, Google Drive, OneDrive ou un NAS monté synchronise. Chaque copie y est relue avant d'être nommée ; leur app l'envoie ensuite en ligne à son rythme, et c'est elle qui dit quand c'est fait.")
                }
            case .ftp, .ftps:
                Section {
                    TextField("Serveur", text: $ingest.settings.upload.host, prompt: Text("ftp.exemple.fr"))
                    TextField("Port", text: port, prompt: Text("21"))
                    TextField("Identifiant", text: $ingest.settings.upload.user, prompt: Text("anonyme si vide"))
                    SecureField("Mot de passe", text: $password)
                        .onSubmit(savePassword)
                    TextField("Dossier", text: $ingest.settings.upload.path, prompt: Text("à la racine du compte"))
                    HStack(spacing: 12) {
                        Button(testing ? "Test en cours…" : "Tester la connexion") { test() }
                            .disabled(testing || !target.isReady)
                        if let testResult {
                            Text(testResult)
                                .font(TypeScale.meta)
                                .foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Help("Les tournages y sont rangés comme sur les disques. Chaque fichier est envoyé sous un nom caché, renommé une fois complet, puis sa taille est demandée au serveur. Un fichier déjà là à sa taille n'est pas renvoyé, et rien n'est jamais remplacé. Le mot de passe est gardé dans le trousseau du Mac." + (target.kind == .ftp ? " En FTP simple, il passe en clair sur le réseau : préfère FTPS si le serveur le propose." : ""))
                }
            }

            if target.kind != .none {
                Section {
                    Toggle("Envoyer dès la fin de chaque sauvegarde", isOn: $ingest.settings.uploadWhenDone)
                    Help("Sinon, la page de fin propose « Envoyer ». Le Mac ne se met pas en veille pendant l'envoi.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .onAppear { password = Keychain.password(for: ingest.settings.upload.keychainAccount) ?? "" }
        .onDisappear(perform: savePassword)
        .onChange(of: target.kind) { _, _ in testResult = nil }
    }

    /// 0, the protocol's own port, reads as an empty field.
    private var port: Binding<String> {
        Binding(
            get: { ingest.settings.upload.port > 0 ? String(ingest.settings.upload.port) : "" },
            set: { ingest.settings.upload.port = Int($0.filter(\.isNumber)).map { min($0, 65535) } ?? 0 }
        )
    }

    private func savePassword() {
        let target = ingest.settings.upload
        guard target.isServer, !target.serverHost.isEmpty else { return }
        Keychain.setPassword(password, for: target.keychainAccount)
    }

    private func test() {
        savePassword()
        let target = ingest.settings.upload
        let password = password
        testing = true
        testResult = nil
        Task {
            let result = await Task.detached { Upload.test(target, password: password) }.value
            testResult = result
            testing = false
        }
    }

    private func chooseFolder() {
        if let folder = chooseUploadFolder() { ingest.settings.upload.folder = folder }
    }
}

/// The ambiance, the titles' face, light or dark.
private struct AppearanceSettings: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        Form {
            Section {
                ForEach(Ambiance.allCases) { ambiance in
                    AmbianceRow(ambiance: ambiance, chosen: ingest.settings.ambiance == ambiance) {
                        ingest.settings.ambiance = ambiance
                    }
                }
            } footer: {
                Help("Les couleurs des signaux (à regarder, ne pas formater) et celles des caméras restent les mêmes dans chaque ambiance, pour se lire pareil.")
            }

            Section {
                Picker("Titres", selection: $ingest.settings.titles) {
                    ForEach(TitleFace.allCases) { Text($0.title).tag($0) }
                }
                Picker("Apparence", selection: $ingest.settings.appearance) {
                    ForEach(IngestSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                Text("Sauvegarde vérifiée")
                    .font(TypeScale.title)
                    .foregroundStyle(Palette.ink)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}

/// One ambiance, drawn with its own colours.
private struct AmbianceRow: View {
    let ambiance: Ambiance
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        let tokens = Palette.Tokens(ambiance)
        Button(action: choose) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tokens.ground)
                    Circle().fill(tokens.accent).padding(5)
                    Circle().strokeBorder(tokens.accentLine, lineWidth: 1.5)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ambiance.title)
                        .font(TypeScale.ui)
                        .foregroundStyle(Palette.ink)
                    Text(ambiance.detail)
                        .font(TypeScale.meta)
                        .foregroundStyle(Palette.inkFaint)
                }
                Spacer()
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accentInk)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
