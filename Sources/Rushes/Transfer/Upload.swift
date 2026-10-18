import Foundation
import Security

/// A copy of the night sent somewhere else once it is verified: a folder the
/// Mac syncs (iCloud Drive, Dropbox, Google Drive, a NAS) or an FTP server.
/// Asked for by Steven on 2026-10-15.
///
/// It comes after the backup and never instead of it. The drives are the
/// backup: what is sent is read from the first drive's verified copy, never
/// from the card again, and a card's verdict does not wait for it nor depend
/// on it. What is sent is held to the drives' rules all the same: nothing on
/// the other side is replaced, a copy is written under a hidden name and named
/// only once it is whole, and a file already there at its size is not sent
/// twice.
struct UploadTarget: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, folder, ftp, ftps
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Aucun"
            case .folder: "Un dossier synchronisé"
            case .ftp: "Un serveur FTP"
            case .ftps: "Un serveur FTPS (chiffré)"
            }
        }
    }

    var kind = Kind.none
    /// For `.folder`: its path on the Mac.
    var folder = ""
    var host = ""
    /// 0 is the protocol's own, 21.
    var port = 0
    /// Empty: anonymous.
    var user = ""
    /// Where the shoots go on the server: from the login folder, or from the
    /// server's root when it starts with `/`.
    var path = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UploadTarget()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? d.folder
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? d.path
    }

    var isServer: Bool { kind == .ftp || kind == .ftps }

    /// Everything its kind needs is filled in.
    var isReady: Bool {
        switch kind {
        case .none: false
        case .folder: !folder.isEmpty
        case .ftp, .ftps: !serverHost.isEmpty
        }
    }

    /// Its name on the page.
    var name: String {
        switch kind {
        case .none: ""
        case .folder: URL(fileURLWithPath: folder).lastPathComponent
        case .ftp, .ftps: serverHost
        }
    }

    /// The host as typed, without a scheme or a path pasted with it.
    var serverHost: String {
        var text = host.trimmingCharacters(in: .whitespaces)
        for scheme in ["ftp://", "ftps://", "sftp://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        return String(text.prefix { $0 != "/" })
    }

    /// The keychain's name for its password.
    var keychainAccount: String { "\(user)@\(serverHost)" }

    /// The server's address for a path under the target's folder, each part
    /// percent-encoded. curl reads a leading `%2F` as the server's root.
    func serverURL(_ relative: String, directory: Bool = false) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))
        let parts = (path.split(separator: "/") + relative.split(separator: "/")).map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
        }
        var text = "ftp://\(serverHost)" + (port > 0 ? ":\(port)" : "") + "/"
        if path.hasPrefix("/") { text += "%2F" }
        text += parts.joined(separator: "/")
        if directory, !parts.isEmpty { text += "/" }
        return URL(string: text)
    }
}

/// One file to send: where it is on the drive, where it goes from the
/// target's folder.
struct UploadItem: Sendable, Hashable {
    let local: URL
    let relative: String
    let size: Int64
    /// The record's hash, to read a copy made on this Mac back against.
    /// Empty for the records themselves.
    let xxh64: String
}

struct UploadProgress: Sendable {
    var done: Int64 = 0
    var total: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var current = ""

    var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
}

struct UploadReport: Sendable {
    var sent = 0
    var bytesSent: Int64 = 0
    /// Already on the other side, at its size: a second send of the same night.
    var alreadyThere = 0
    var failures: [BackupReport.Failure] = []
    var cancelled = false
    /// What stopped everything: the server unreachable, the password refused,
    /// the folder gone.
    var stopped: String?

    var succeeded: Bool { failures.isEmpty && !cancelled && stopped == nil }
}

enum Upload {
    /// What tonight's backup verified, read from the drives, followed by the
    /// records of the night (manifest, CSV, report), so the copy sent can be
    /// asked months later as the drives can.
    ///
    /// Each file is read from the first drive that holds it: with the photos
    /// on one disk and the videos on another, both halves are sent. Each
    /// drive's records list its own half and bear the same names, so a second
    /// drive's are sent with its name added rather than over the first's.
    static func items(of report: BackupReport, on drives: [URL]) -> [UploadItem] {
        var items: [UploadItem] = []
        var taken: Set<String> = []
        let stamp = History.stamp(report.recorded)
        let page = TransferReport.fileName(report.recorded)
        // A report that does not say which drive holds what lists everything
        // under the first drive.
        let byDrive = report.onDrives.isEmpty && !drives.isEmpty ? [drives[0].path: report.entries] : report.onDrives
        for (folder, _) in report.entries.sorted(by: { $0.key < $1.key }) {
            func relative(_ path: String) -> String { folder.isEmpty ? path : folder + "/" + path }
            for drive in drives {
                guard let entries = byDrive[drive.path]?[folder] else { continue }
                let shoot = folder.isEmpty ? drive : drive.appendingPathComponent(folder)
                for entry in entries where taken.insert(relative(entry.path).lowercased()).inserted {
                    items.append(UploadItem(local: shoot.appendingPathComponent(entry.path), relative: relative(entry.path), size: entry.size, xxh64: entry.xxh64))
                }
                let records = shoot.appendingPathComponent(History.folderName)
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).sorted()
                for name in names where name.hasPrefix(stamp) || name == page {
                    let url = records.appendingPathComponent(name)
                    guard let size = size(of: url) else { continue }
                    var sent = relative(History.folderName + "/" + name)
                    if !taken.insert(sent.lowercased()).inserted {
                        let ext = (name as NSString).pathExtension
                        let tag = Sanitize.field(drive.lastPathComponent)
                        sent = relative(History.folderName + "/" + (name as NSString).deletingPathExtension + "-" + tag + (ext.isEmpty ? "" : "." + ext))
                        guard taken.insert(sent.lowercased()).inserted else { continue }
                    }
                    items.append(UploadItem(local: url, relative: sent, size: size, xxh64: ""))
                }
            }
        }
        return items
    }

    enum Outcome { case sent, alreadyThere }

    static func run(
        _ items: [UploadItem],
        to target: UploadTarget,
        password: String?,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) -> UploadReport {
        var report = UploadReport()
        var state = UploadProgress()
        state.filesTotal = items.count
        state.total = items.reduce(0) { $0 + $1.size }
        progress(state)

        outer: for item in items {
            if isCancelled() {
                report.cancelled = true
                break
            }
            state.current = (item.relative as NSString).lastPathComponent
            progress(state)
            let before = state.done
            do {
                let advance: (Int64) -> Void = { sent in
                    state.done = before + min(sent, item.size)
                    progress(state)
                }
                let outcome: Outcome
                switch target.kind {
                case .none:
                    break outer
                case .folder:
                    outcome = try toFolder(item, root: URL(fileURLWithPath: target.folder), isCancelled: isCancelled, advance: advance)
                case .ftp, .ftps:
                    outcome = try toServer(item, target: target, password: password, isCancelled: isCancelled, advance: advance)
                }
                switch outcome {
                case .sent:
                    report.sent += 1
                    report.bytesSent += item.size
                case .alreadyThere:
                    report.alreadyThere += 1
                }
            } catch {
                if isCancelled() {
                    report.cancelled = true
                    break outer
                }
                if let failure = error as? Copier.Failure, failure.fatal {
                    report.stopped = failure.message
                    break outer
                }
                report.failures.append(.init(file: item.relative, message: error.localizedDescription))
            }
            state.done = before + item.size
            state.filesDone += 1
            progress(state)
        }
        return report
    }

    // MARK: A folder the Mac syncs

    /// Copied beside its final name, read back against the record, named
    /// with `RENAME_EXCL`. Read back on this Mac only: whether the service
    /// then sends it on is the service's business, and it says so itself.
    private static func toFolder(
        _ item: UploadItem,
        root: URL,
        isCancelled: @escaping () -> Bool,
        advance: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Copier.Failure(message: "Le dossier « \(root.lastPathComponent) » est introuvable.", fatal: true)
        }
        let target = root.appendingPathComponent(item.relative)
        if let existing = size(of: target) {
            if existing == item.size { return .alreadyThere }
            throw Copier.Failure(message: "« \(target.lastPathComponent) » existe déjà dans « \(root.lastPathComponent) », à une autre taille. Rien n'a été remplacé.")
        }
        guard size(of: item.local) == item.size else {
            throw Copier.Failure(message: "« \(item.local.lastPathComponent) » n'est plus sur \(Copier.volumeName(of: item.local)) à sa taille : rien n'a été envoyé.")
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = Copier.partialURL(for: target)
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: item.local, to: partial)
            if !item.xxh64.isEmpty {
                var read: Int64 = 0
                let check = try Copier.hash(of: partial, isCancelled: isCancelled) { bytes in
                    read += bytes
                    advance(read)
                }
                guard check == item.xxh64 else {
                    throw Copier.Failure(message: "La copie de « \(target.lastPathComponent) » dans « \(root.lastPathComponent) » ne correspond pas au relevé.")
                }
            }
            try Copier.name(partial, target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return .sent
    }

    // MARK: A server, through the Mac's own curl

    /// Sent under a hidden name, renamed once the transfer is whole, then
    /// asked for its size. FTP has no hash to ask for, so a size is all the
    /// server can be held to.
    private static func toServer(
        _ item: UploadItem,
        target: UploadTarget,
        password: String?,
        isCancelled: @escaping () -> Bool,
        advance: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let name = (item.relative as NSString).lastPathComponent
        let folder = (item.relative as NSString).deletingLastPathComponent
        let partialName = ".\(name).rushes-partial"
        guard let final = target.serverURL(item.relative),
              let partial = target.serverURL(folder.isEmpty ? partialName : folder + "/" + partialName)
        else { throw Copier.Failure(message: "Adresse du serveur illisible : « \(target.host) ».", fatal: true) }

        if let existing = try remoteSize(final, target: target, password: password, isCancelled: isCancelled) {
            if existing == item.size { return .alreadyThere }
            throw Copier.Failure(message: "« \(name) » existe déjà sur \(target.serverHost), à une autre taille. Rien n'a été remplacé.")
        }
        guard size(of: item.local) == item.size else {
            throw Copier.Failure(message: "« \(item.local.lastPathComponent) » n'est plus sur \(Copier.volumeName(of: item.local)) à sa taille : rien n'a été envoyé.")
        }

        // The rename runs after a whole transfer only, in the folder the
        // transfer went to: a cut leaves a hidden partial, never the name.
        let sent = curl(
            ["--ftp-create-dirs", "--upload-file", item.local.path, partial.absoluteString,
             "--quote", "-RNFR \(partialName)", "--quote", "-RNTO \(name)"],
            target: target, password: password, isCancelled: isCancelled
        ) { fraction in advance(Int64(Double(item.size) * fraction)) }
        if isCancelled() { throw Copier.Failure(message: "Envoi interrompu.") }
        guard sent.status == 0 else { throw failure(sent, target: target) }

        guard let landed = try remoteSize(final, target: target, password: password, isCancelled: isCancelled) else {
            throw Copier.Failure(message: "« \(name) » a été envoyé mais \(target.serverHost) ne le trouve pas sous son nom.")
        }
        guard landed == item.size || landed < 0 else {
            throw Copier.Failure(message: "« \(name) » fait \(Format.bytes(landed)) sur \(target.serverHost) au lieu de \(Format.bytes(item.size)).")
        }
        return .sent
    }

    /// Whether the server answers and lets this user in, said in a sentence
    /// for the settings.
    static func test(_ target: UploadTarget, password: String?) -> String {
        guard let url = target.serverURL("", directory: true) else { return "Adresse du serveur illisible." }
        let result = curl(["--list-only", url.absoluteString], target: target, password: password, isCancelled: { false })
        switch result.status {
        case 0: return "Connexion réussie."
        case 9, 19, 78: return "Connecté. Le dossier n'existe pas encore : il sera créé au premier envoi."
        default: return failure(result, target: target).message
        }
    }

    /// The size of a file on the server, nil if it is not there, -1 if the
    /// server will not say.
    private static func remoteSize(_ url: URL, target: UploadTarget, password: String?, isCancelled: @escaping () -> Bool) throws -> Int64? {
        let result = curl(["--head", url.absoluteString], target: target, password: password, isCancelled: isCancelled)
        if isCancelled() { throw Copier.Failure(message: "Envoi interrompu.") }
        if result.status == 0 {
            for line in result.output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length",
                   let value = Int64(parts[1].trimmingCharacters(in: .whitespaces)) {
                    return value
                }
            }
            return -1
        }
        // A file or a folder not there yet.
        if [9, 19, 78].contains(result.status) { return nil }
        throw failure(result, target: target)
    }

    /// What curl said, in French. The connection itself failing stops the
    /// whole send; anything else costs one file.
    private static func failure(_ result: CurlResult, target: UploadTarget) -> Copier.Failure {
        let host = target.serverHost
        switch result.status {
        case 6: return .init(message: "Le serveur « \(host) » est introuvable : vérifie son adresse.", fatal: true)
        case 7: return .init(message: "\(host) ne répond pas.", fatal: true)
        case 28: return .init(message: "\(host) a mis trop de temps à répondre.", fatal: true)
        case 67: return .init(message: "\(host) refuse l'identifiant ou le mot de passe.", fatal: true)
        case 64: return .init(message: "\(host) ne propose pas de connexion chiffrée : choisis FTP, ou demande FTPS à l'hébergeur.", fatal: true)
        case 35, 51, 58, 59, 60, 77, 83, 90, 91:
            return .init(message: "La connexion chiffrée avec \(host) a échoué : son certificat n'est peut-être pas reconnu par le Mac.", fatal: true)
        case 23, 25:
            return .init(message: "\(host) a refusé d'écrire le fichier : dossier en lecture seule ou disque plein ?")
        default:
            let said = result.error.split(whereSeparator: \.isNewline).last { $0.hasPrefix("curl:") }.map(String.init) ?? ""
            return .init(message: "L'envoi vers \(host) a échoué (curl \(result.status))\(said.isEmpty ? "." : " : \(said)")")
        }
    }

    struct CurlResult {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs the Mac's curl. The password goes in on standard input as a
    /// config line, never on the command line, where `ps` would show it.
    /// `fraction` turns on curl's progress bar and is called with how much of
    /// an upload is done.
    private static func curl(
        _ arguments: [String],
        target: UploadTarget,
        password: String?,
        isCancelled: () -> Bool,
        fraction: ((Double) -> Void)? = nil
    ) -> CurlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = ["--config", "-", "--show-error", "--connect-timeout", "20",
                    // A transfer that moves nothing for two minutes is stuck.
                    "--speed-limit", "1", "--speed-time", "120"]
        args.append(fraction == nil ? "--silent" : "--progress-bar")
        if target.kind == .ftps { args.append("--ssl-reqd") }
        process.arguments = args + arguments

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let out = Buffer(), err = Buffer()
        output.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return CurlResult(status: -1, output: "", error: "curl: \(error.localizedDescription)")
        }
        var config = ""
        if !target.user.isEmpty {
            config += "user = \"\(escape(target.user)):\(escape(password ?? ""))\"\n"
        }
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        while process.isRunning {
            if isCancelled() { process.terminate() }
            if let fraction, let value = err.lastPercent { fraction(value / 100) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        out.append(output.fileHandleForReading.readDataToEndOfFile())
        err.append(errors.fileHandleForReading.readDataToEndOfFile())
        return CurlResult(status: process.terminationStatus, output: out.text, error: err.text)
    }

    /// curl's config quoting: a backslash and a double quote are escaped.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// What a pipe gave, filled from its reading thread.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

        /// The last figure of curl's progress bar, which ends each refresh
        /// with a carriage return: "######   45.2%".
        var lastPercent: Double? {
            let tail = lock.withLock { String(decoding: data.suffix(256), as: UTF8.self) }
            guard let last = tail.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last(where: { $0.contains("%") }),
                  let number = last.split(separator: " ").last(where: { $0.hasSuffix("%") })
            else { return nil }
            return Double(number.dropLast().replacingOccurrences(of: ",", with: "."))
        }
    }
}

/// The server's password, in the login keychain under Rushes' name. Never in
/// the settings, which are a plain file anyone can read.
enum Keychain {
    static let service = "eu.stevenrsl.rushes.upload"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the password kept for this account; an empty one forgets it.
    static func setPassword(_ password: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Rushes, envoi vers \(account)"
        SecItemAdd(add as CFDictionary, nil)
    }
}
