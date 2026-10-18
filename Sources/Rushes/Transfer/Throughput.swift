import Foundation

/// The speed of a backup over its length, for the curve on the copying page
/// (asked 2026-10-17, "un peu comme Windows"). Bytes moved are summed into
/// bins of time rather than smoothed, so a bin says exactly what moved in it;
/// past `maxBins` the bins are merged two by two and grow twice as wide, so a
/// night of three hours costs as much to draw as a minute.
struct ThroughputHistory: Sendable {
    struct Bin: Sendable, Equatable {
        var bytes: Double = 0
        var seconds: Double = 0
        /// Of those seconds, the ones spent reading the drives back.
        var verifying: Double = 0

        var rate: Double { seconds > 0 ? bytes / seconds : 0 }
        var isVerifying: Bool { seconds > 0 && verifying * 2 > seconds }

        static func + (a: Bin, b: Bin) -> Bin {
            Bin(bytes: a.bytes + b.bytes, seconds: a.seconds + b.seconds, verifying: a.verifying + b.verifying)
        }
    }

    static let maxBins = 240

    private(set) var bins: [Bin] = []
    /// The seconds each bin covers.
    private(set) var width: TimeInterval = 1
    /// Seconds since the backup started, up to the last sample.
    private(set) var elapsed: TimeInterval = 0

    var peak: Double { bins.map(\.rate).max() ?? 0 }

    /// `bytes` moved in the `seconds` that ended `time` seconds after the
    /// start. The whole interval goes to the bin of its middle.
    mutating func add(at time: TimeInterval, seconds: TimeInterval, bytes: Int64, verifying: Bool) {
        guard seconds > 0, time >= 0 else { return }
        elapsed = max(elapsed, time)
        let middle = max(time - seconds / 2, 0)
        while Int(middle / width) >= Self.maxBins { coarsen() }
        let index = Int(middle / width)
        if bins.count <= index { bins.append(contentsOf: repeatElement(Bin(), count: index + 1 - bins.count)) }
        bins[index].bytes += Double(max(bytes, 0))
        bins[index].seconds += seconds
        if verifying { bins[index].verifying += seconds }
    }

    private mutating func coarsen() {
        bins = stride(from: 0, to: bins.count, by: 2).map { i in
            i + 1 < bins.count ? bins[i] + bins[i + 1] : bins[i]
        }
        width *= 2
    }
}
