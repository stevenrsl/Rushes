import Foundation
import ImageIO

/// When each shot was taken, which sets both its day in the name and its place
/// in the numbering.
///
/// Photos: EXIF DateTimeOriginal, read by ImageIO from the header only (no
/// pixels are decoded), from the group's JPEG when there is one because it is
/// the fastest to open. Videos and anything unreadable keep the file system's
/// date, the earlier of creation and modification: for a clip, the start of the
/// recording. MP4 headers are not trusted for this: many cameras write local
/// time where the format says UTC.
///
/// Dates are the camera's wall clock, read and written in the Mac's time zone,
/// so 23:40 on the camera is 23:40 in the name whatever the offset.
enum CaptureDates {
    struct Exif: Sendable {
        var date: Date?
        var make: String?
        var model: String?
        var serial: String?
    }

    static func exif(of url: URL) -> Exif {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return Exif() }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let stamp = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        return Exif(
            date: stamp.flatMap(parse),
            make: (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            model: (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            serial: (exif?[kCGImagePropertyExifBodySerialNumber] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// "2026:09:21 23:41:07", EXIF's own format, without a formatter so it can
    /// run on every core at once.
    static func parse(_ stamp: String) -> Date? {
        let numbers = stamp.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 6, numbers[0] > 1900 else { return nil }
        var parts = DateComponents()
        parts.year = numbers[0]
        parts.month = numbers[1]
        parts.day = numbers[2]
        parts.hour = numbers[3]
        parts.minute = numbers[4]
        parts.second = numbers[5]
        return Calendar.current.date(from: parts)
    }

    /// Reads the EXIF of every photo group, several at a time: a card answers
    /// parallel reads faster than one after the other. `progress` is called
    /// from any thread with the count done. The camera returned is the body
    /// most of the photos come from.
    static func enrich(_ groups: [MediaGroup], progress: (@Sendable (Int) -> Void)? = nil) -> (groups: [MediaGroup], camera: CameraIdentity?) {
        let targets = groups.enumerated().compactMap { index, group in group.exifSource.map { (index, $0.url) } }
        guard !targets.isEmpty else { return (groups, nil) }
        var results = [Exif?](repeating: nil, count: targets.count)
        let lock = NSLock()
        var done = 0
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                slots[i] = exif(of: targets[i].1)
                lock.lock()
                done += 1
                let count = done
                lock.unlock()
                if count % 25 == 0 || count == targets.count { progress?(count) }
            }
        }
        var enriched = groups
        var cameras: [CameraIdentity: Int] = [:]
        for (slot, (index, _)) in targets.enumerated() {
            guard let found = results[slot] else { continue }
            if let date = found.date { enriched[index].captureDate = date }
            if let model = found.model, !model.isEmpty {
                let name = displayName(make: found.make, model: model)
                enriched[index].cameraModel = name
                let serial = found.serial.flatMap { $0.isEmpty || $0.allSatisfy { $0 == "0" } ? nil : $0 }
                cameras[CameraIdentity(name: name, serial: serial), default: 0] += 1
            }
        }
        return (enriched, cameras.max { $0.value < $1.value }?.key)
    }

    /// "Canon EOS R5", "SONY ILCE-7M4" → "Sony ILCE-7M4": the make once, in
    /// the case people write it.
    static func displayName(make: String?, model: String) -> String {
        guard let make, !make.isEmpty else { return model }
        let brand = CameraBrand.allCases.first { make.uppercased().contains($0.rawValue.uppercased()) }?.rawValue
            ?? make.capitalized
        let firstWord = make.split(separator: " ").first.map(String.init) ?? make
        if model.uppercased().hasPrefix(firstWord.uppercased()) {
            return brand + model.dropFirst(firstWord.count)
        }
        return "\(brand) \(model)"
    }
}
