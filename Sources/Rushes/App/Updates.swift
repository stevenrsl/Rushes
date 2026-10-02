import AppKit
import Foundation

/// Rushes › Rechercher une mise à jour…: asks GitHub for the published
/// releases, only when that menu is chosen. Nothing else in the app touches
/// the network, and this never runs by itself (decided 2026-10-01, rather
/// than Sparkle: no dependency, no signing key to keep, nothing in the
/// background). It only says; the person downloads the new .dmg.
enum UpdateCheck {
    static let releasesURL = URL(string: "https://api.github.com/repos/stevenrsl/Rushes/releases?per_page=30")!

    struct Release: Equatable {
        let version: ReleaseVersion
        let page: URL
    }

    /// The newest release in GitHub's answer, drafts left out. Pre-releases
    /// count: during the beta every release is one.
    static func newest(in json: Data) -> Release? {
        struct Entry: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: json) else { return nil }
        return entries
            .filter { $0.draft != true && $0.html_url.host() == "github.com" }
            .compactMap { entry in ReleaseVersion(entry.tag_name).map { Release(version: $0, page: entry.html_url) } }
            .max { $0.version < $1.version }
    }

    enum Outcome: Equatable {
        case newer(Release)
        case upToDate
        case nothingPublished
        case unreachable
    }

    static func outcome(current: ReleaseVersion, answer: Data?) -> Outcome {
        guard let answer else { return .unreachable }
        guard (try? JSONSerialization.jsonObject(with: answer)) is [Any] else { return .unreachable }
        guard let newest = newest(in: answer) else { return .nothingPublished }
        return newest.version > current ? .newer(newest) : .upToDate
    }

    @MainActor
    static func run() async {
        let current = Bundle.main.version
        var request = URLRequest(url: releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Rushes/\(current)", forHTTPHeaderField: "User-Agent")
        // No cookie, no cache: the question leaves nothing behind.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var answer: Data?
        if let (data, response) = try? await session.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            answer = data
        }
        show(outcome(current: ReleaseVersion(current) ?? ReleaseVersion("0")!, answer: answer), current: current)
    }

    @MainActor
    private static func show(_ outcome: Outcome, current: String) {
        let alert = NSAlert()
        switch outcome {
        case .newer(let release):
            alert.messageText = "Rushes \(release.version.text) est disponible"
            alert.informativeText = "Tu as la version \(current). La page de la version dit ce qui change et propose le fichier à télécharger."
            alert.addButton(withTitle: "Ouvrir la page")
            alert.addButton(withTitle: "Plus tard")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.page)
            }
            return
        case .upToDate:
            alert.messageText = "Rushes est à jour"
            alert.informativeText = "Tu as la version \(current), la plus récente."
        case .nothingPublished:
            alert.messageText = "Aucune version publiée"
            alert.informativeText = "Il n'y a encore aucune version de Rushes sur GitHub. Tu as la version \(current)."
        case .unreachable:
            alert.alertStyle = .warning
            alert.messageText = "GitHub ne répond pas"
            alert.informativeText = "Vérifie la connexion à Internet, puis réessaie."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// "v0.3.0-beta.2", "0.3", "1.0.1": numbers compared one by one, missing ones
/// as zero, and a pre-release before the release it leads to.
struct ReleaseVersion: Comparable, Equatable {
    let numbers: [Int]
    let prerelease: String?

    /// As the tag says it, without the "v".
    let text: String

    init?(_ tag: String) {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.map { $0! }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
        self.text = text
    }

    static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}
