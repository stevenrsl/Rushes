import AppKit
import Foundation
import Observation
import UserNotifications

/// Everything the window shows: the cards, the drives, the settings, the plan
/// they make together, and the backup once it runs. Scanning, planning and
/// copying happen off the main thread; their results land here.
@MainActor
@Observable
final class Ingest {
    struct Card: Identifiable {
        enum State {
            case scanning(String)
            case ready(CardScan)
            case failed(String)
        }

        let url: URL
        var name: String
        /// A mounted card can be ejected; a folder added by hand cannot.
        var isVolume: Bool
        var cameraLabel: String
        /// Typed by hand in this session: a scan that ends afterwards does not
        /// put the remembered letter back over it.
        var labelByHand = false
        var included = true
        var state: State = .scanning("Lecture de la carte…")

        var id: String { url.path }
        var scan: CardScan? { if case .ready(let scan) = state { scan } else { nil } }
    }

    struct Drive: Identifiable, Hashable {
        let url: URL
        var name: String
        var available: Int64?
        var total: Int64?
        var isOnline: Bool
        /// `msdos` is FAT32, which cannot hold a file of 4 GB.
        var fileSystem: String?
        /// The volume it sits on, read with the drives rather than at every
        /// redraw: two folders on one volume are one copy.
        var volume: String
        var id: String { url.path }
    }

    enum Phase {
        case preparing
        case copying
        case finished(BackupReport)
    }

    var cards: [Card] = []
    var drives: [Drive] = []
    var settings: IngestSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.destinations != oldValue.destinations { refreshDrives() }
            schedulePlan()
        }
    }
    /// A day typed by hand for the whole backup. Not remembered: the next
    /// night is another day.
    var fixedDay: ShootDay? { didSet { schedulePlan() } }
    private(set) var plan = IngestPlan()
    /// A plan is being made: for the 150 ms after a change, and the time the
    /// drives take to answer. The page says so instead of "rien à copier".
    private(set) var isPlanning = false
    private(set) var phase: Phase = .preparing
    private(set) var progress = BackupProgress()
    /// Bytes read from the cards per second, smoothed.
    private(set) var speed: Double = 0
    private(set) var remaining: TimeInterval?
    /// When a byte last moved. A copy that is slow and one that is stuck look
    /// the same on a percentage; this tells them apart.
    private(set) var lastMoved = Date()
    private(set) var ejectMessage: String?
    private(set) var ejected = false

    private let watcher = VolumeWatcher()
    private let cancelFlag = CancelFlag()
    private var planTask: Task<Void, Never>?
    private var planGeneration = 0
    private var activity: NSObjectProtocol?
    /// Set while the app is on its way out: see `stopForQuit`.
    private var onQuit: (() -> Void)?
    private var lastSample: (date: Date, read: Int64, done: Int64)?
    private var doneRate: Double = 0

    init() {
        settings = IngestSettings.load()
        watcher.onChange = { [weak self] in self?.volumesChanged() }
        refreshDrives()
        volumesChanged()
    }

    // MARK: Cards

    var readyCards: [Card] { cards.filter { $0.included && $0.scan != nil } }
    /// A card being read holds the backup back only if it is ticked: a big
    /// card left out does not make the others wait.
    var isScanning: Bool {
        cards.contains { card in
            guard card.included, case .scanning = card.state else { return false }
            return true
        }
    }
    var isCopying: Bool { if case .copying = phase { true } else { false } }

    private func volumesChanged() {
        refreshDrives()
        guard !isCopying else { return }
        let drivePaths = Set(drives.compactMap { VolumeWatcher.volume(of: $0.url)?.path })
        let mounted = watcher.volumes.filter { !drivePaths.contains($0.path) && CardScanner.looksLikeCard($0) }
        // Cards pulled out go; folders added by hand stay.
        cards.removeAll { card in card.isVolume && !mounted.contains { $0.path == card.url.path } }
        for volume in mounted where !cards.contains(where: { $0.url.path == volume.path }) {
            add(volume, isVolume: true)
        }
        schedulePlan()
    }

    func addFolder(_ url: URL) {
        guard !cards.contains(where: { $0.url.path == url.path }) else { return }
        add(url, isVolume: false)
    }

    private func add(_ url: URL, isVolume: Bool) {
        // A letter to show while the card is read; its camera's comes after.
        let label = CameraLetters.letter(for: nil, known: settings.cameras, taken: Set(cards.map(\.cameraLabel)))
        let name = isVolume ? VolumeWatcher.name(of: url) : url.lastPathComponent
        cards.append(Card(url: url, name: name, isVolume: isVolume, cameraLabel: label))
        scan(url)
    }

    func remove(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        schedulePlan()
    }

    func rescan(_ card: Card) {
        update(card.id) { $0.state = .scanning("Lecture de la carte…") }
        scan(card.url)
    }

    func setIncluded(_ card: Card, _ included: Bool) {
        update(card.id) { $0.included = included }
        schedulePlan()
    }

    /// A letter typed on a card is its camera's from now on.
    func setLabel(_ card: Card, _ label: String) {
        let clean = String(Sanitize.code(label).prefix(3))
        guard !clean.isEmpty else { return }
        update(card.id) {
            $0.cameraLabel = clean
            $0.labelByHand = true
        }
        if let camera = cards.first(where: { $0.id == card.id })?.scan?.camera {
            settings.cameras = CameraLetters.remembering(camera, label: clean, in: settings.cameras)
        }
        schedulePlan()
    }

    func forgetCamera(_ camera: KnownCamera) {
        settings.cameras.removeAll { $0.id == camera.id }
    }

    func relabelCamera(_ camera: KnownCamera, _ label: String) {
        let clean = String(Sanitize.code(label).prefix(3))
        guard !clean.isEmpty, let i = settings.cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        settings.cameras[i].label = clean
        for card in cards where card.scan?.camera?.id == camera.id {
            update(card.id) { $0.cameraLabel = clean }
        }
        schedulePlan()
    }

    /// Whether this card's letter is the one remembered for its camera.
    func isRemembered(_ card: Card) -> Bool {
        guard let id = card.scan?.camera?.id else { return false }
        return settings.cameras.contains { $0.id == id && $0.label == card.cameraLabel }
    }

    /// Once a card is read and its camera known, it takes that camera's letter.
    private func applyCameraLetter(_ id: String) {
        guard let card = cards.first(where: { $0.id == id }), !card.labelByHand else { return }
        let taken = Set(cards.filter { $0.id != id }.map(\.cameraLabel))
        let letter = CameraLetters.letter(for: card.scan?.camera?.id, known: settings.cameras, taken: taken)
        update(id) { $0.cameraLabel = letter }
    }

    private func update(_ id: String, _ change: (inout Card) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[i])
    }

    /// The model lives as long as the app and belongs to the main actor, so
    /// the background work holds it directly.
    private func scan(_ url: URL) {
        let id = url.path
        Task.detached(priority: .userInitiated) {
            do {
                var scan = try CardScanner.scan(url)
                let total = scan.groups.filter { $0.exifSource != nil }.count
                if total > 0 {
                    await self.setScanning(id, "Dates des photos… 0 / \(total)")
                }
                let (groups, fromPhotos) = CaptureDates.enrich(scan.groups) { done in
                    Task { @MainActor in self.setScanning(id, "Dates des photos… \(done) / \(total)") }
                }
                let camera = fromPhotos
                    ?? CameraLetters.sonyDevice(in: scan.groups)
                    ?? (scan.brand == .unknown ? nil : CameraIdentity(name: scan.brand.rawValue, serial: nil))
                scan = CardScan(root: scan.root, groups: groups, orphans: scan.orphans, unknown: scan.unknown, unreadableFolders: scan.unreadableFolders, brand: scan.brand, camera: camera, setAside: scan.setAside)
                let finished = scan
                await MainActor.run {
                    self.update(id) { $0.state = .ready(finished) }
                    self.applyCameraLetter(id)
                    self.schedulePlan()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.update(id) { $0.state = .failed(message) } }
            }
        }
    }

    private func setScanning(_ id: String, _ message: String) {
        update(id) { card in
            if case .scanning = card.state { card.state = .scanning(message) }
        }
    }

    // MARK: Kinds of files

    struct KindCount: Identifiable {
        let kind: FileKind
        var files = 0
        var bytes: Int64 = 0
        var id: String { kind.id }
    }

    /// The kinds of file on the cards in use, in the order they are shown:
    /// photos (RAW first), videos, sounds, then what comes with them.
    var presentKinds: [KindCount] {
        var counts: [FileKind: KindCount] = [:]
        for card in readyCards {
            for group in card.scan!.groups {
                for file in group.files {
                    counts[file.kind, default: KindCount(kind: file.kind)].files += 1
                    counts[file.kind]!.bytes += file.size
                }
            }
        }
        return counts.values.sorted { $0.kind.order < $1.kind.order }
    }

    func includes(_ kind: FileKind) -> Bool { settings.includes(kind) }

    /// Ticks or unticks a kind, for this backup and the next ones.
    func toggle(_ kind: FileKind) {
        settings.kindChoices[kind.id] = !settings.includes(kind)
    }

    // MARK: Drives

    func addDrive(_ url: URL) {
        guard !settings.destinations.contains(url.path) else { return }
        settings.destinations.append(url.path)
    }

    func removeDrive(_ drive: Drive) {
        settings.destinations.removeAll { $0 == drive.url.path }
    }

    private func refreshDrives() {
        drives = settings.destinations.map { path in
            let url = URL(fileURLWithPath: path)
            var isFolder: ObjCBool = false
            let online = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
            let volume = online ? VolumeWatcher.volume(of: url) : nil
            let name = volume.map { v in v.path == "/" ? url.lastPathComponent : VolumeWatcher.name(of: v) } ?? url.lastPathComponent
            return Drive(
                url: url,
                name: name,
                available: online ? VolumeWatcher.availableBytes(at: url) : nil,
                total: online ? VolumeWatcher.totalBytes(at: url) : nil,
                isOnline: online,
                fileSystem: online ? VolumeWatcher.fileSystem(of: url) : nil,
                volume: volume?.path ?? path
            )
        }
    }

    var onlineDrives: [Drive] { drives.filter(\.isOnline) }

    // MARK: Plan

    func schedulePlan() {
        // The plan running is the one that counts until it ends; `reset`
        // makes the next one. Remembering tonight's client at ⌘↩ used to
        // replan 150 ms into the copy.
        guard !isCopying else { return }
        isPlanning = true
        planTask?.cancel()
        planGeneration += 1
        let generation = planGeneration
        let sources = readyCards.map { card in
            PlanSource(id: card.id, volumeName: card.name, cameraLabel: card.cameraLabel, groups: card.scan!.groups)
        }
        let settings = settings
        let fixedDay = fixedDay
        let drives = onlineDrives.map(\.url)
        planTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let plan = {
                var plan = Planner.plan(sources: sources, settings: settings, fixedDay: fixedDay, drives: drives, isCancelled: { Task.isCancelled })
                plan.drives = drives.map(\.path)
                plan.generation = generation
                plan.namePattern = settings.namePattern
                return plan
            }()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == self.planGeneration else { return }
                self.plan = plan
                self.isPlanning = false
            }
        }
    }

    /// The day the shots belong to when nothing is typed: the cards' own.
    var detectedDays: [ShootDay] {
        let dates = readyCards.flatMap { $0.scan!.groups.map(\.captureDate) }
        return Array(Set(dates.map { ShootDay(date: $0, cutoffHour: settings.dayCutoffHour) })).sorted()
    }

    /// Why the button is not ready, the most useful first.
    var blockers: [String] {
        Readiness(
            cards: cards.count,
            scanning: isScanning,
            planning: isPlanning || !isCurrent,
            ready: readyCards.count,
            cardWithoutLetter: readyCards.contains { $0.cameraLabel.isEmpty },
            drives: drives.map { .init(name: $0.name, isOnline: $0.isOnline, available: $0.available, fileSystem: $0.fileSystem, volume: $0.volume) },
            settings: settings,
            plan: plan
        ).blockers
    }

    /// What this backup will not cover, said before it runs rather than found
    /// out after. None of it holds the button back: a card read in part is
    /// still worth saving tonight, it just must not look whole afterwards.
    var warnings: [String] {
        var list: [String] = []
        for card in readyCards {
            guard let scan = card.scan, !scan.isComplete else { continue }
            let folders = Format.count(scan.unreadableFolders.count, "dossier")
            list.append("« \(card.name) » n'a pas pu être lue entièrement : \(folders) illisible\(scan.unreadableFolders.count > 1 ? "s" : ""). Elle ne sera pas éjectée.")
        }
        let unknown = readyCards.reduce(0) { $0 + ($1.scan?.unknownCount ?? 0) }
        if unknown > 0 {
            list.append("\(Format.count(unknown, "fichier")) d'un type que Rushes ne connaît pas \(unknown > 1 ? "restent" : "reste") sur la carte, sous « Laissés sur la carte ».")
        }
        let aside = readyCards.reduce(0) { $0 + ($1.scan?.setAside.count ?? 0) }
        if aside > 0 {
            list.append("\(Format.count(aside, "photo ou vidéo", "photos ou vidéos")) \(aside > 1 ? "sont cachées ou rangées" : "est cachée ou rangée") là où l'appareil range ses propres fichiers. Rushes ne \(aside > 1 ? "les" : "la") copie pas, et \(aside > 1 ? "les" : "la") nomme sous « Laissés sur la carte ».")
        }
        return list
    }

    /// What each card was told at the end of the last backup: the page's last
    /// word, and the one the camera acts on.
    private(set) var verdicts: [CardVerdict] = []
    /// The plan being run, kept apart from the one on screen: a setting
    /// changed while copying makes a new plan, and a card's verdict must be
    /// judged on what was actually asked of the drives, not on that one.
    private var runningPlan = IngestPlan()

    /// The drives the last backup wrote to, by name, even if one has since
    /// been unplugged.
    var backupDriveNames: [String] {
        runningPlan.drives.map { path in
            drives.first { $0.url.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// The cards nothing was left behind on. A card told "ne pas formater" is
    /// never ejected: ejecting it is the moment it goes back in the camera.
    var ejectableCards: [Card] {
        readyCards.filter { card in
            guard let verdict = verdicts.first(where: { $0.cardID == card.id }) else { return false }
            return verdict.level != .hold
        }
    }

    /// The plan on screen is the one the current cards, drives and settings
    /// make. Anything else must not be started, whatever the button says.
    private var isCurrent: Bool {
        plan.generation == planGeneration && plan.drives == onlineDrives.map(\.url.path)
    }

    var canStart: Bool { blockers.isEmpty && !plan.toCopy.isEmpty && !isCopying && isCurrent }

    // MARK: Backup

    func start() {
        guard canStart else { return }
        // The plan's own drives, not today's: the two are equal here, and this
        // is the pair that was counted, named and checked against.
        let drives = plan.drives.map { URL(fileURLWithPath: $0) }
        settings.recentClients = IngestSettings.remembering(settings.client, in: settings.recentClients)
        settings.recentProjects = IngestSettings.remembering(settings.project, in: settings.recentProjects)
        let plan = plan
        runningPlan = plan
        cancelFlag.reset()
        verdicts = []
        phase = .copying
        progress = BackupProgress()
        speed = 0
        doneRate = 0
        remaining = nil
        lastSample = nil
        lastMoved = .now
        ejectMessage = nil
        ejected = false
        // The screen may sleep; the Mac may not, and quitting is refused.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Sauvegarde des cartes en cours"
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let flag = cancelFlag
        Task.detached(priority: .userInitiated) {
            let report = Backup.run(plan, drives: drives, isCancelled: { flag.isSet }) { state in
                Task { @MainActor in self.advance(state) }
            }
            await MainActor.run { self.finish(report) }
        }
    }

    func cancel() { cancelFlag.set() }

    /// A quit in the middle of a backup: the copy stops, and the app waits for
    /// the record to be written before it goes. The names the cameras gave the
    /// files of tonight live nowhere else.
    func stopForQuit(_ done: @escaping () -> Void) {
        guard isCopying else { return done() }
        onQuit = done
        cancel()
    }

    private func advance(_ state: BackupProgress) {
        guard isCopying else { return }
        if state.done != progress.done || state.filesDone != progress.filesDone { lastMoved = .now }
        progress = state
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.date)
            if dt >= 0.5 {
                let readRate = Double(state.read - last.read) / dt
                let rate = Double(state.done - last.done) / dt
                speed = speed == 0 ? readRate : speed * 0.8 + readRate * 0.2
                doneRate = doneRate == 0 ? rate : doneRate * 0.8 + rate * 0.2
                if doneRate > 0 { remaining = Double(state.total - state.done) / doneRate }
                lastSample = (now, state.read, state.done)
            }
        } else {
            lastSample = (now, state.read, state.done)
        }
    }

    private func finish(_ report: BackupReport) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        verdicts = readyCards.compactMap { card in
            guard let scan = card.scan else { return nil }
            return Verdicts.of(cardID: card.id, cardName: card.name, scan: scan, plan: runningPlan, report: report)
        }
        writeReports(report)
        if let onQuit {
            self.onQuit = nil
            onQuit()
            return
        }
        phase = .finished(report)
        remember(report)
        refreshDrives()
        notify(report)
        if report.succeeded, settings.ejectWhenDone, !ejectableCards.isEmpty {
            Task { await ejectCards() }
        }
    }

    /// The readable reports of the last backup, first drive first.
    private(set) var reportURLs: [URL] = []

    /// Writes the page a person reads beside each shoot's manifest, on every
    /// drive, once the cards have been told. A report that cannot be written
    /// costs nothing but itself: the JSON and the CSV are already there.
    private func writeReports(_ report: BackupReport) {
        reportURLs = []
        let names = backupDriveNames
        let cards = verdicts.map { verdict in
            TransferReport.Card(
                name: verdict.cardName, title: verdict.title, sentence: verdict.sentence,
                level: verdict.level == .safe ? "safe" : verdict.level == .check ? "check" : "hold"
            )
        }
        let file = TransferReport.fileName(report.finished)
        for path in runningPlan.drives {
            let drive = URL(fileURLWithPath: path)
            for (folder, entries) in report.entries.sorted(by: { $0.key < $1.key }) {
                let html = TransferReport.html(
                    shoot: folder, report: report, entries: entries, cards: cards,
                    drives: names, version: Bundle.main.version
                )
                let url = (folder.isEmpty ? drive : drive.appendingPathComponent(folder))
                    .appendingPathComponent(History.folderName)
                    .appendingPathComponent(file)
                if (try? Data(html.utf8).write(to: url, options: .atomic)) != nil { reportURLs.append(url) }
            }
        }
    }

    /// Keeps the pace of a backup long enough to say something, for the next
    /// night's estimate. Small ones are all overhead and would promise too
    /// much; the drives' count is part of it, since each is read back.
    private func remember(_ report: BackupReport) {
        let seconds = report.finished.timeIntervalSince(report.started)
        guard report.succeeded, report.bytesCopied >= 256 << 20, seconds > 5 else { return }
        let moved = Double(report.bytesCopied) * Double(1 + runningPlan.drives.count)
        settings.measuredThroughput = moved / seconds
    }

    /// How long the plan on screen should take, from the last backup's pace.
    var estimatedDuration: TimeInterval? {
        guard settings.measuredThroughput > 0, plan.bytesToCopy > 0 else { return nil }
        let moved = Double(plan.bytesToCopy) * Double(1 + max(onlineDrives.count, 1))
        return moved / settings.measuredThroughput
    }

    private func notify(_ report: BackupReport) {
        let content = UNMutableNotificationContent()
        if report.succeeded {
            content.title = "Sauvegarde vérifiée"
            var body = "\(Format.count(report.filesCopied, "fichier")) · \(Format.bytes(report.bytesCopied)) sur \(Format.count(runningPlan.drives.count, "disque"))."
            // The last word is about the cards, because that is what gets
            // formatted in the morning.
            let held = verdicts.filter { $0.level != .safe }
            body += held.isEmpty
                ? " Toutes les cartes sont formatables. Tu peux aller dormir."
                : " \(Format.count(held.count, "carte")) à regarder avant de formater."
            content.body = body
        } else if report.cancelled {
            content.title = "Sauvegarde interrompue"
            content.body = "\(Format.count(report.filesCopied, "fichier")) copiés et vérifiés avant l'arrêt."
        } else {
            content.title = "Sauvegarde incomplète"
            content.body = report.stopped
                ?? (report.failures.isEmpty
                    ? "Un disque n'a pas confirmé avoir tout écrit. Ne formate pas les cartes ce soir."
                    : "\(Format.count(report.failures.count, "fichier")) n'\(report.failures.count > 1 ? "ont" : "a") pas pu être copié\(report.failures.count > 1 ? "s" : "").")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Ejects the cards that were backed up. Folders added by hand are left.
    func ejectCards() async {
        let volumes = ejectableCards.filter(\.isVolume).map(\.url)
        var refused: [String] = []
        for url in volumes {
            do {
                try await VolumeWatcher.eject(url)
            } catch {
                refused.append(url.lastPathComponent)
            }
        }
        ejected = refused.isEmpty && !volumes.isEmpty
        ejectMessage = refused.isEmpty
            ? (volumes.isEmpty ? nil : volumes.count > 1 ? "Cartes éjectées." : "Carte éjectée.")
            : "« \(refused.joined(separator: "», «")) » n'a pas pu être éjectée : une autre app la lit peut-être."
    }

    /// Back to the preparation, with the plan made again so what was just
    /// copied shows as saved and what failed can be tried again.
    func reset() {
        phase = .preparing
        progress = BackupProgress()
        refreshDrives()
        let known = Set(cards.map(\.id))
        volumesChanged()
        // A card still here may have been shot on since it was read.
        for card in cards where known.contains(card.id) { rescan(card) }
    }
}

/// Read from the copying thread, set from the main one.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}
