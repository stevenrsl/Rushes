import Foundation

/// A page a person can open, print or send: what one backup put in one
/// shoot's folder, and what each card was told.
///
/// The JSON is for Rushes and the CSV for a spreadsheet; this is for the
/// client who asks what was delivered, the editor who asks where DSC01234
/// went, and Steven the morning after. It sits beside them in `_RUSHES/` and
/// travels with the folder. Like the CSV it is derived: nothing ever reads it
/// back, and losing it costs nothing the JSON does not still hold.
///
/// It is one self-contained file, no script and nothing fetched, so it opens
/// the same way on any machine in ten years.
enum TransferReport {
    struct Card: Sendable {
        var name: String
        var title: String
        var sentence: String
        /// safe, check or hold: the colour of the line.
        var level: String
    }

    static func fileName(_ date: Date) -> String {
        "rapport-\(History.stamp(date)).html"
    }

    static func html(
        shoot: String,
        report: BackupReport,
        entries: [Manifest.Entry],
        cards: [Card],
        drives: [String],
        version: String
    ) -> String {
        let french = Locale(identifier: "fr_FR")
        let day = report.started.formatted(.dateTime.locale(french).weekday(.wide).day().month(.wide).year())
        let start = report.started.formatted(.dateTime.locale(french).hour().minute())
        let end = report.finished.formatted(.dateTime.locale(french).hour().minute())
        let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let title = shoot.isEmpty ? "Sauvegarde" : shoot

        var html = """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Rushes \(escape(version))">
        <title>\(escape(title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <p class="trail">\(escape(day.prefix(1).uppercased() + day.dropFirst())) · de \(start) à \(end)</p>
        <h1>\(escape(title))</h1>
        <p class="aim">\(escape(summary(report, entries: entries, bytes: bytes, drives: drives)))</p>

        """

        html += section("Bilan", """
        <dl>
        <dt>Fichiers</dt><dd>\(Format.number(entries.count))</dd>
        <dt>Volume</dt><dd>\(escape(Format.bytes(bytes)))</dd>
        <dt>Disques</dt><dd>\(escape(drives.joined(separator: ", ")))</dd>
        <dt>Durée</dt><dd>\(escape(Format.duration(report.finished.timeIntervalSince(report.started))))</dd>
        <dt>Vérification</dt><dd>xxh64, chaque copie relue sur le disque</dd>
        </dl>
        """)

        if !cards.isEmpty {
            let rows = cards.map { card in
                """
                <li class="\(escape(card.level))"><span class="card">\(escape(card.name))</span> <span class="verdict">\(escape(card.title))</span><br>\(escape(card.sentence))</li>
                """
            }
            html += section("Cartes", "<ul class=\"verdicts\">\n" + rows.joined(separator: "\n") + "\n</ul>")
        }

        if report.stopped != nil || !report.failures.isEmpty {
            var body = ""
            if let stopped = report.stopped { body += "<p class=\"alert\">\(escape(stopped))</p>\n" }
            body += "<ul class=\"failures\">\n"
            for failure in report.failures {
                body += "<li><code>\(escape(failure.file))</code><br>\(escape(failure.message))</li>\n"
            }
            html += section("Pas copiés", body + "</ul>")
        }

        if !entries.isEmpty {
            var table = """
            <table>
            <thead><tr><th>Fichier</th><th>Nom d'origine</th><th>Carte</th><th class="n">Taille</th><th>xxh64</th></tr></thead>
            <tbody>

            """
            for e in entries.sorted(by: { $0.path < $1.path }) {
                table += "<tr><td><code>\(escape(e.path))</code></td><td><code>\(escape(e.original))</code></td><td>\(escape(e.volume))</td><td class=\"n\">\(escape(Format.bytes(e.size)))</td><td><code>\(escape(e.xxh64))</code></td></tr>\n"
            }
            html += section("Fichiers", table + "</tbody>\n</table>")
        }

        html += """
        <p class="colophon">Écrit par Rushes \(escape(version)). Le relevé complet, lisible par une machine, est à côté : même dossier, même heure, en JSON et en CSV.</p>
        </main>
        </body>
        </html>

        """
        return html
    }

    private static func summary(_ report: BackupReport, entries: [Manifest.Entry], bytes: Int64, drives: [String]) -> String {
        let what = "\(Format.count(entries.count, "fichier")), \(Format.bytes(bytes))"
        let onto = drives.count > 1 ? "sur \(drives.count) disques" : "sur un disque"
        if report.succeeded {
            return "\(what) copiés \(onto), chacun relu sur le disque et comparé à la carte."
        }
        if report.cancelled {
            return "\(what) copiés et vérifiés \(onto) avant que la sauvegarde soit interrompue."
        }
        return "\(what) copiés et vérifiés \(onto). La sauvegarde est incomplète : voir ci-dessous."
    }

    private static func section(_ title: String, _ body: String) -> String {
        "<section>\n<h2>\(escape(title))</h2>\n<div>\n\(body)\n</div>\n</section>\n"
    }

    static func escape<S: StringProtocol>(_ text: S) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// The app's own tokens, from `Palette`, light and dark.
    private static let style = """
    :root {
      --ground: oklch(0.962 0.011 118); --surface: oklch(0.988 0.006 105);
      --ink: oklch(0.25 0.020 160); --ink-soft: oklch(0.44 0.020 160); --ink-faint: oklch(0.515 0.018 155);
      --hairline: oklch(0.885 0.014 120); --accent-ink: oklch(0.46 0.085 155);
      --late: oklch(0.50 0.120 50); --alert: oklch(0.54 0.135 12);
      color-scheme: light dark;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --ground: oklch(0.195 0.014 165); --surface: oklch(0.232 0.015 165);
        --ink: oklch(0.94 0.010 110); --ink-soft: oklch(0.77 0.014 130); --ink-faint: oklch(0.655 0.014 140);
        --hairline: oklch(0.31 0.014 165); --accent-ink: oklch(0.82 0.075 150);
        --late: oklch(0.74 0.110 50); --alert: oklch(0.74 0.120 12);
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--ground); color: var(--ink);
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    main { max-width: 980px; margin: 0 auto; padding: 48px 16px 64px; }
    h1, h2 { font-family: ui-serif, "New York", Georgia, serif; font-weight: 500; }
    h1 { font-size: 34px; line-height: 1.15; margin: 4px 0 8px; overflow-wrap: anywhere; }
    h2 { font-size: 17px; margin: 0; }
    .trail { color: var(--ink-faint); margin: 0; font-size: 13px; }
    .aim { color: var(--ink-soft); font-style: italic; margin: 0 0 24px; }
    section { display: grid; grid-template-columns: 150px 1fr; gap: 16px; padding: 20px 0; border-top: 1px solid var(--hairline); }
    section > div { min-width: 0; }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: 6px 24px; margin: 0; }
    dt { color: var(--ink-faint); } dd { margin: 0; font-variant-numeric: tabular-nums; }
    ul { list-style: none; margin: 0; padding: 0; } li { margin: 0 0 10px; color: var(--ink-soft); }
    .card { color: var(--ink); } .verdict { font-size: 12px; margin-left: 6px; }
    .safe .verdict { color: var(--accent-ink); } .check .verdict { color: var(--late); }
    .hold .verdict, .alert { color: var(--alert); }
    code { font: 12px ui-monospace, "SF Mono", Menlo, monospace; color: var(--ink); overflow-wrap: anywhere; }
    table { width: 100%; border-collapse: collapse; font-size: 12px; }
    th { text-align: left; font-weight: 500; color: var(--ink-faint); border-bottom: 1px solid var(--hairline); padding: 4px 8px 4px 0; }
    td { border-bottom: 1px solid var(--hairline); padding: 4px 8px 4px 0; vertical-align: top; }
    .n { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .colophon { color: var(--ink-faint); font-size: 12px; margin-top: 32px; }
    @media (max-width: 640px) {
      section { grid-template-columns: 1fr; gap: 8px; }
      section > div { overflow-x: auto; }
    }
    @media print {
      :root { --ground: #fff; } main { padding-top: 0; } section { break-inside: avoid-page; }
    }
    """
}
