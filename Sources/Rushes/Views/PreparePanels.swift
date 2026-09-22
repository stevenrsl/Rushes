import AppKit
import SwiftUI

/// Who and what: the day, the initials, the client, the project.
struct ShootBlock: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Field(label: "Jour") { dayPicker }
                    Field(label: "Initiales") {
                        // "SR" alone reads as a value already typed, and the
                        // field is the one thing nobody checks at 3 a.m.
                        TextField("Par exemple, SR", text: $ingest.settings.initials)
                    }
                    .frame(width: 110)
                }
                GridRow {
                    Field(label: "Client") {
                        RecentField(placeholder: "Par exemple, Kaffi", text: $ingest.settings.client, recents: ingest.settings.recentClients)
                    }
                    Field(label: "Projet") {
                        RecentField(placeholder: "Par exemple, Lexus", text: $ingest.settings.project, recents: ingest.settings.recentProjects)
                    }
                }
            }
        }
    }

    private var dayPicker: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Selon l'heure des prises") { ingest.fixedDay = nil }
                if !ingest.detectedDays.isEmpty {
                    Divider()
                    ForEach(ingest.detectedDays, id: \.self) { day in
                        Button("Tout au " + Format.day(day)) { ingest.fixedDay = day }
                    }
                }
                Divider()
                Button("Choisir une date…") {
                    ingest.fixedDay = ShootDay(date: .now, cutoffHour: ingest.settings.dayCutoffHour)
                }
            } label: {
                Text(dayLabel)
                    .font(TypeScale.ui)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            if let fixed = ingest.fixedDay {
                DatePicker("", selection: Binding(
                    get: { fixed.date },
                    set: { ingest.fixedDay = ShootDay(date: $0, cutoffHour: 0) }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
            }
        }
        .help("Jusqu'à \(ingest.settings.dayCutoffHour) h du matin, une prise compte pour la veille : un tournage de nuit garde sa date.")
    }

    private var dayLabel: String {
        if let fixed = ingest.fixedDay { return "Fixé : " + Format.day(fixed) }
        let days = ingest.detectedDays
        switch days.count {
        case 0: return "Selon l'heure des prises"
        case 1: return Format.day(days[0]).prefix(1).uppercased() + Format.day(days[0]).dropFirst()
        default: return "\(days.count) jours, un dossier chacun"
        }
    }
}

/// A text field with the last values typed a click away.
private struct RecentField: View {
    let placeholder: String
    @Binding var text: String
    let recents: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
            if !recents.isEmpty {
                Menu {
                    ForEach(recents, id: \.self) { value in
                        Button(value) { text = value }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Palette.inkFaint)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Récents")
                .accessibilityLabel("Récents")
            }
        }
    }
}

/// The drives the cards go to. Two is a backup; one is a copy.
struct DrivesBlock: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ingest.drives.isEmpty {
                Text("Choisis le dossier où ranger les tournages sur ton SSD. Il sera retenu.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(ingest.drives) { drive in
                DriveRow(drive: drive, incoming: ingest.plan.bytesToCopy)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Button(ingest.drives.isEmpty ? "Choisir un disque…" : "Ajouter un disque…") { chooseDrive() }
                    .buttonStyle(.accentLink)
                    .font(TypeScale.meta)
                    .disabled(ingest.isCopying)
                Text(ingest.drives.count > 1
                     ? "La carte est lue une fois et écrite sur chaque disque en même temps."
                     : "Avec un second disque, tu as une vraie sauvegarde pour le même temps.")
                    .font(TypeScale.micro)
                    .foregroundStyle(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseDrive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Le dossier où Rushes range les tournages. Il sera retenu pour les prochaines fois."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            ingest.addDrive(url)
        }
    }
}

private struct DriveRow: View {
    @Environment(Ingest.self) private var ingest
    let drive: Ingest.Drive
    let incoming: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: drive.isOnline ? "externaldrive" : "externaldrive.badge.xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(drive.isOnline ? Palette.inkSoft : Palette.late)
                    .frame(width: 16)
                Text(drive.name)
                    .font(TypeScale.ui)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(status)
                    .font(TypeScale.meta)
                    .foregroundStyle(tight || !drive.isOnline ? Palette.late : Palette.inkFaint)
                    .monospacedDigit()
                Button {
                    ingest.removeDrive(drive)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.inkFaint)
                }
                .buttonStyle(.plain)
                .disabled(ingest.isCopying)
                .help("Ne plus copier ici")
                .accessibilityLabel("Ne plus copier sur « \(drive.name) »")
            }
            if drive.isOnline, let total = drive.total, let free = drive.available, total > 0 {
                Bar(fraction: Double(total - free) / Double(total), height: 4, fill: Palette.hairlineStrong,
                    extra: Double(incoming) / Double(total), extraFill: tight ? Palette.late : Palette.accentLine)
                    .frame(maxWidth: 360)
                    .padding(.leading, 25)
            }
            Text(drive.url.path)
                .font(TypeScale.micro)
                .foregroundStyle(Palette.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 25)
        }
        .help(drive.url.path)
    }

    private var tight: Bool { (drive.available ?? .max) < incoming }

    private var status: String {
        guard drive.isOnline else { return "Non branché" }
        guard let free = drive.available else { return "" }
        return "\(Format.bytes(free)) libres"
    }
}

/// How files are named, with the name they will get in front of you.
struct NamingBlock: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        @Bindable var ingest = ingest
        let preset = NamePreset.matching(ingest.settings.namePattern)
        VStack(alignment: .leading, spacing: 14) {
            Flow(spacing: 6) {
                ForEach(NamePreset.allCases) { p in
                    Chip(text: p.title, selected: preset == p) { ingest.settings.namePattern = p.pattern }
                }
                // Not a choice: it lights up when the pattern is edited.
                Chip(text: "Personnalisé", selected: preset == nil) {}
                    .allowsHitTesting(false)
            }

            Field(label: "Modèle", help: preset?.detail ?? "Modèle personnalisé : les jetons entre accolades sont remplacés, le reste est gardé tel quel.", monospaced: true) {
                TextField("{YYMMDD}_{INIT}_{CLIENT}_{PROJET}_{NUM}", text: $ingest.settings.namePattern)
            }

            Flow(spacing: 14) {
                ForEach(NameToken.allCases, id: \.self) { token in
                    Button("+ " + token.label) {
                        let pattern = ingest.settings.namePattern
                        let separator = pattern.isEmpty || pattern.hasSuffix("_") || pattern.hasSuffix("-") ? "" : "_"
                        ingest.settings.namePattern = pattern + separator + "{\(token.rawValue)}"
                    }
                    .buttonStyle(.accentLink)
                    .font(TypeScale.meta)
                    .help("{\(token.rawValue)} : \(token.help)")
                }
            }

            example
        }
    }

    /// The first shot's name, and where it goes.
    @ViewBuilder
    private var example: some View {
        let first = ingest.plan.toCopy.first ?? ingest.plan.groups.first { !$0.baseName.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            if let first {
                ForEach(first.files.filter(\.file.role.isPrimary)) { planned in
                    HStack(spacing: 8) {
                        Text(planned.file.name)
                            .foregroundStyle(Palette.inkFaint)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.inkFaint)
                        Text("\(Text(subfolder(of: planned, in: first)).foregroundStyle(Palette.inkFaint))\(Text(planned.name).foregroundStyle(Palette.accentInk))")
                            .textSelection(.enabled)
                    }
                    .font(TypeScale.code)
                }
                if let drive = ingest.onlineDrives.first {
                    Text("dans " + drive.name + "/" + (first.shootFolder.isEmpty ? "" : first.shootFolder + "/"))
                        .font(TypeScale.micro)
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(NameTemplate(ingest.settings.namePattern).render(sample) + ".ARW")
                    .font(TypeScale.code)
                    .foregroundStyle(Palette.accentInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.accentSoft))
    }

    /// `PHOTO/RAW/`: where the file goes inside the shoot's folder.
    private func subfolder(of planned: PlannedFile, in group: PlannedGroup) -> String {
        var folder = (planned.relativePath as NSString).deletingLastPathComponent
        if !group.shootFolder.isEmpty { folder = String(folder.dropFirst(group.shootFolder.count)) }
        folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? "" : folder + "/"
    }

    private var sample: NameValues {
        NameValues(
            day: ingest.fixedDay ?? ShootDay(date: .now, cutoffHour: ingest.settings.dayCutoffHour),
            time: "213000",
            initials: Sanitize.code(ingest.settings.initials).isEmpty ? "XX" : Sanitize.code(ingest.settings.initials),
            client: Sanitize.field(ingest.settings.client).isEmpty ? "Client" : Sanitize.field(ingest.settings.client),
            project: Sanitize.field(ingest.settings.project).isEmpty ? "Projet" : Sanitize.field(ingest.settings.project),
            camera: ingest.cards.first?.cameraLabel ?? "A",
            original: "DSC01234",
            type: "PHOTO",
            number: 1,
            padding: ingest.settings.padding
        )
    }
}

/// Which kinds of file go: every kind on the cards, by family, one click each.
/// The choice is kept for the next cards: XML left once is left every night.
struct FilesBlock: View {
    @Environment(Ingest.self) private var ingest

    var body: some View {
        let kinds = ingest.presentKinds
        let families = FileKind.Family.allCases.filter { family in kinds.contains { $0.kind.family == family } }
        VStack(alignment: .leading, spacing: 12) {
            if kinds.isEmpty {
                Text(ingest.isScanning ? "Lecture des cartes…" : "Les types de fichiers des cartes apparaîtront ici.")
                    .font(TypeScale.meta)
                    .foregroundStyle(Palette.inkFaint)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(families, id: \.self) { family in
                        GridRow(alignment: .firstTextBaseline) {
                            GroupLabel(text: family.title)
                                .frame(minWidth: 84, alignment: .leading)
                            Flow(spacing: 6) {
                                ForEach(kinds.filter { $0.kind.family == family }) { count in
                                    KindChip(count: count, ticked: ingest.includes(count.kind)) {
                                        ingest.toggle(count.kind)
                                    }
                                    .disabled(ingest.isCopying)
                                }
                            }
                        }
                    }
                }
                Text("Ton choix est retenu pour les prochaines cartes. Une photo dont tu ne gardes que le RAW garde son numéro ; une prise dont rien n'est coché reste sur la carte, avec ses métadonnées.")
                    .font(TypeScale.micro)
                    .foregroundStyle(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A kind of file, ticked or not: its extension and how many there are.
private struct KindChip: View {
    let count: Ingest.KindCount
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                Text(count.kind.ext)
                    .font(TypeScale.meta.weight(.medium))
                Text(Format.number(count.files))
                    .font(TypeScale.numbers)
                    .opacity(0.7)
            }
            .foregroundStyle(ticked ? Palette.onAccent : Palette.inkFaint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(ticked ? Palette.accent : .clear))
            .overlay(Capsule().strokeBorder(ticked ? .clear : Palette.hairlineStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(Format.count(count.files, "fichier")), \(Format.bytes(count.bytes)), \(ticked ? "copiés" : "laissés sur la carte")")
        .accessibilityLabel("\(count.kind.ext), \(Format.count(count.files, "fichier"))")
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }
}
