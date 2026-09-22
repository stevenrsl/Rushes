// Writes a fake camera card, to try Rushes without a shoot.
//
//     swift Tools/make-test-card.swift sony /Volumes/SONY
//     swift Tools/make-test-card.swift canon /Volumes/CANON
//     swift Tools/make-test-card.swift dji /Volumes/DRONE
//
// Best on a real exFAT volume, which Rushes then finds on its own:
//
//     hdiutil create -size 200m -fs ExFAT -volname SONY -layout MBRSPUD /tmp/sony.dmg
//     hdiutil attach /tmp/sony.dmg
//
// The JPEGs are real, small, with the EXIF date and camera a real one has.
// RAW files and clips are random bytes of a plausible size: Rushes copies
// them, it does not open them. Shots run from 21:00 to past midnight, so the
// night shoot's date can be seen at work.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, ["sony", "canon", "dji"].contains(args[1]) else {
    print("usage: swift Tools/make-test-card.swift sony|canon|dji <folder>")
    exit(1)
}
let brand = args[1]
let root = URL(fileURLWithPath: args[2])
let calendar = Calendar.current
let start = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: .now)!

func write(_ relative: String, _ data: Data, at date: Date) {
    let url = root.appendingPathComponent(relative)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
}

func noise(_ size: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    for i in stride(from: 0, to: size, by: 4096) { bytes[i] = UInt8.random(in: 0...255) }
    return Data(bytes)
}

func jpeg(at date: Date, make: String, model: String, hue: Double) -> Data {
    let width = 96, height = 64
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2 + hue * 0.6, green: 0.3, blue: 0.8 - hue * 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: f.string(from: date)],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model],
    ]
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

// A photo every few minutes, a clip now and then, a card index, some junk.
var shot = start
if brand == "sony" {
    for n in 1...24 {
        shot = shot.addingTimeInterval(Double.random(in: 300...600))
        let name = String(format: "DSC%05d", 1200 + n)
        write("DCIM/100MSDCF/\(name).JPG", jpeg(at: shot, make: "SONY", model: "ILCE-7M4", hue: Double(n) / 24), at: shot)
        if n % 3 != 0 { write("DCIM/100MSDCF/\(name).ARW", noise(2_400_000), at: shot) }
        if n % 6 == 0 {
            let clip = String(format: "C%04d", n / 6)
            let end = shot.addingTimeInterval(40)
            write("PRIVATE/M4ROOT/CLIP/\(clip).MP4", noise(9_000_000), at: end)
            write("PRIVATE/M4ROOT/CLIP/\(clip)M01.XML", Data("<NonRealTimeMeta/>".utf8), at: end)
            write("PRIVATE/M4ROOT/THMBNL/\(clip)T01.JPG", jpeg(at: end, make: "SONY", model: "ILCE-7M4", hue: 0.5), at: end)
        }
    }
    write("PRIVATE/M4ROOT/MEDIAPRO.XML", Data("<MediaProfile/>".utf8), at: start)
    write("PRIVATE/M4ROOT/STATUS.BIN", noise(512), at: start)
    write("AVF_INFO/AVIN0001.BNP", noise(1024), at: start)
} else if brand == "dji" {
    for n in 1...10 {
        shot = shot.addingTimeInterval(Double.random(in: 200...500))
        let name = String(format: "DJI_%04d", 100 + n)
        if n % 4 == 0 {
            write("DCIM/100MEDIA/\(name).MP4", noise(8_000_000), at: shot)
            write("DCIM/100MEDIA/\(name).SRT", Data("1\n00:00:00,000 --> 00:00:01,000\n[latitude: 48.85]\n".utf8), at: shot)
            write("DCIM/100MEDIA/\(name).LRF", noise(900_000), at: shot)
        } else {
            write("DCIM/100MEDIA/\(name).JPG", jpeg(at: shot, make: "DJI", model: "FC3582", hue: Double(n) / 10), at: shot)
            write("DCIM/100MEDIA/\(name).DNG", noise(2_000_000), at: shot)
        }
    }
} else {
    for n in 1...14 {
        shot = shot.addingTimeInterval(Double.random(in: 400...900))
        let name = String(format: "IMG_%04d", 3400 + n)
        write("DCIM/100EOSR5/\(name).JPG", jpeg(at: shot, make: "Canon", model: "Canon EOS R5", hue: 1 - Double(n) / 14), at: shot)
        write("DCIM/100EOSR5/\(name).CR3", noise(3_000_000), at: shot)
        if n % 5 == 0 {
            write(String(format: "DCIM/100EOSR5/MVI_%04d.MP4", 3400 + n + 100), noise(12_000_000), at: shot.addingTimeInterval(30))
        }
    }
    write("MISC/DPOF.CTG", noise(64), at: start)
}
print("\(brand) card written in \(root.path)")
