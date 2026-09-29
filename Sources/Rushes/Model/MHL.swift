import CryptoKit
import Foundation

/// The ASC Media Hash List (v2.0) of a shoot folder, for DITs and post houses.
///
/// Rushes' own record is the JSON in `_RUSHES/`; this says the same thing in
/// the standard every offload tool and every post house reads, so a folder
/// handed over can be checked with `ascmhl verify` or Silverstack without
/// Rushes. The layout is the standard's, not ours: an `ascmhl/` folder at the
/// root of the folder it covers, one numbered hash list per backup
/// (`0001_<folder>_<yyyy-MM-dd>_<HHmmss>Z.mhl`, in UTC), and
/// `ascmhl_chain.xml`, which seals each generation with the C4 id of its bytes
/// so none can be edited or dropped unseen. Each backup adds a generation and
/// never rewrites one.
///
/// Written against the schema in github.com/ascmitc/mhl (`xsd/ASCMHL.xsd`,
/// `xsd/ASCMHLDirectory.xsd`), 2026-09-29. The C4 id was checked against the
/// chain of that repository's examples.
enum ASCMHL {
    static let folderName = "ascmhl"
    static let chainName = "ascmhl_chain.xml"

    /// SHA-512 as a base-58 number, padded to 88 digits, after "c4": the
    /// SMPTE ST 2114 id the chain seals each hash list with.
    static func c4(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var number = Array(SHA512.hash(data: data))
        var digits: [Character] = []
        // Long division of the 512-bit number by 58, most significant byte first.
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices {
                let value = remainder << 8 | Int(number[i])
                number[i] = UInt8(value / 58)
                remainder = value % 58
            }
            digits.append(alphabet[remainder])
        }
        let body = String(digits.reversed())
        return "c4" + String(repeating: "1", count: max(0, 88 - body.count)) + body
    }

    struct File {
        /// From the folder the list covers.
        var path: String
        var size: Int64
        var modified: Date?
        var xxh64: String
    }

    /// One generation: what this backup put in the folder, each file's hash
    /// as read from the card and verified on the drive.
    static func hashList(_ files: [File], at date: Date, host: String, version: String) -> String {
        let iso = ISO8601DateFormatter()
        let when = iso.string(from: date)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(when)</creationdate>
            <hostname>\(escape(host))</hostname>
            <tool version="\(escape(version))">Rushes</tool>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
            <ignore>
              <pattern>.DS_Store</pattern>
              <pattern>ascmhl</pattern>
              <pattern>ascmhl/</pattern>
              <pattern>_RUSHES</pattern>
              <pattern>_RUSHES/</pattern>
            </ignore>
          </processinfo>
          <hashes>

        """
        for file in files.sorted(by: { $0.path < $1.path }) {
            let modified = file.modified.map { " lastmodificationdate=\"\(iso.string(from: $0))\"" } ?? ""
            xml += """
                <hash>
                  <path size="\(file.size)"\(modified)>\(escape(file.path))</path>
                  <xxh64 action="original" hashdate="\(when)">\(file.xxh64)</xxh64>
                </hash>

            """
        }
        xml += """
          </hashes>
        </hashlist>

        """
        return xml
    }

    static func chain(_ lists: [(sequence: Int, path: String, c4: String)]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">

        """
        for list in lists.sorted(by: { $0.sequence < $1.sequence }) {
            xml += """
              <hashlist sequencenr="\(list.sequence)">
                <path>\(escape(list.path))</path>
                <c4>\(list.c4)</c4>
              </hashlist>

            """
        }
        return xml + "</ascmhldirectory>\n"
    }

    /// The generations a chain already lists, read with the XML parser so a
    /// chain written by another tool is kept whole.
    static func readChain(_ url: URL) -> [(sequence: Int, path: String, c4: String)] {
        guard let document = try? XMLDocument(contentsOf: url, options: []) else { return [] }
        let lists = (try? document.nodes(forXPath: "//*[local-name()='hashlist']")) ?? []
        return lists.compactMap { node in
            guard let element = node as? XMLElement,
                  let sequence = element.attribute(forName: "sequencenr")?.stringValue.flatMap(Int.init),
                  let path = element.elements(forName: "path").first?.stringValue,
                  let c4 = element.elements(forName: "c4").first?.stringValue
            else { return nil }
            return (sequence, path, c4)
        }
    }

    /// Adds this backup's generation to the shoot folder's history.
    @discardableResult
    static func write(_ entries: [Manifest.Entry], in shootFolder: URL, at date: Date, version: String) throws -> URL? {
        guard !entries.isEmpty else { return nil }
        let folder = shootFolder.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chainURL = folder.appendingPathComponent(chainName)
        var lists = readChain(chainURL)
        // A list left without a chain (a copy cut off between the two) still
        // holds its number.
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { name in name.hasSuffix(".mhl") ? Int(name.prefix(4)) : nil }
        let sequence = (lists.map(\.sequence) + onDisk).max().map { $0 + 1 } ?? 1

        let files = entries.map { entry in
            let values = try? shootFolder.appendingPathComponent(entry.path).resourceValues(forKeys: [.contentModificationDateKey])
            return File(path: entry.path, size: entry.size, modified: values?.contentModificationDate, xxh64: entry.xxh64)
        }
        let host = ProcessInfo.processInfo.hostName
        let data = Data(hashList(files, at: date, host: host, version: version).utf8)

        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = String(format: "%04d", sequence) + "_" + shootFolder.lastPathComponent + "_" + utc.string(from: date) + "Z.mhl"
        let url = folder.appendingPathComponent(name)
        // Never over a list already there: a generation is not rewritten.
        try data.write(to: url, options: .withoutOverwriting)
        lists.append((sequence, name, c4(data)))
        try Data(chain(lists).utf8).write(to: chainURL, options: .atomic)
        return url
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
