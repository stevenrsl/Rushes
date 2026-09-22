import Foundation

/// Which body a card came from, so the letter chosen for it once comes back
/// by itself. Steven asked for it on 2026-09-21: A for the A7 IV, D for the
/// drone, every night without typing it.
struct CameraIdentity: Hashable, Sendable {
    /// "Sony ILCE-7M4", as shown on the card.
    let name: String
    /// The body's serial when the camera writes one (EXIF BodySerialNumber,
    /// Sony's clip XML). Two A7 IV on one shoot are then two cameras.
    let serial: String?

    /// What its letter is remembered under.
    var id: String { serial.map { "\(name) #\($0)" } ?? name }
}

/// A camera whose letter was chosen by hand, kept in the settings.
struct KnownCamera: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String
}

enum CameraLetters {
    static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

    /// The letter a card gets: its camera's, unless another card of this backup
    /// already shows it (two bodies the camera could not tell apart). Otherwise
    /// the first letter no card shows and no known camera holds, so a new body
    /// never borrows the drone's D.
    static func letter(for id: String?, known: [KnownCamera], taken: Set<String>) -> String {
        if let id, let camera = known.first(where: { $0.id == id }), !taken.contains(camera.label) {
            return camera.label
        }
        let reserved = Set(known.map(\.label))
        return alphabet.first { !taken.contains($0) && !reserved.contains($0) }
            ?? alphabet.first { !taken.contains($0) }
            ?? "Z"
    }

    /// Puts a camera's letter in the list, replacing what it had.
    static func remembering(_ camera: CameraIdentity, label: String, in known: [KnownCamera]) -> [KnownCamera] {
        var list = known.filter { $0.id != camera.id }
        list.append(KnownCamera(id: camera.id, name: camera.name, label: label))
        return list.sorted { ($0.label, $0.name) < ($1.label, $1.name) }
    }

    /// Sony writes the body in each clip's XML:
    /// `<Device manufacturer="Sony" modelName="ILME-FX3" serialNo="1234567"/>`.
    /// Read from the first one, for cards that hold only video.
    static func sonyDevice(in groups: [MediaGroup]) -> CameraIdentity? {
        guard let xml = groups.lazy.flatMap(\.files).first(where: { $0.role == .sidecar && $0.name.uppercased().hasSuffix("M01.XML") }),
              let handle = try? FileHandle(forReadingFrom: xml.url)
        else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 32_768), as: UTF8.self)
        return device(inSonyXML: head)
    }

    static func device(inSonyXML text: String) -> CameraIdentity? {
        guard let tag = text.firstMatch(of: #/<Device\b[^>]*>/#).map({ String($0.output) }),
              let model = tag.firstMatch(of: #/modelName="([^"]+)"/#)?.output.1
        else { return nil }
        let maker = tag.firstMatch(of: #/manufacturer="([^"]+)"/#)?.output.1 ?? "Sony"
        let serial = tag.firstMatch(of: #/serialNo="([^"]+)"/#)?.output.1
        return CameraIdentity(
            name: CaptureDates.displayName(make: String(maker), model: String(model)),
            serial: serial.map(String.init)
        )
    }
}
