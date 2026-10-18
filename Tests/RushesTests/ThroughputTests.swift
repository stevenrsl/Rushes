import Testing
@testable import Rushes

@Suite("Throughput")
struct ThroughputTests {
    @Test func binsSayWhatMoved() {
        var history = ThroughputHistory()
        history.add(at: 0.5, seconds: 0.5, bytes: 50, verifying: false)
        history.add(at: 1.0, seconds: 0.5, bytes: 150, verifying: false)
        history.add(at: 2.0, seconds: 1, bytes: 300, verifying: true)
        #expect(history.bins.count == 2)
        #expect(history.bins[0].rate == 200)
        #expect(!history.bins[0].isVerifying)
        #expect(history.bins[1].rate == 300)
        #expect(history.bins[1].isVerifying)
        #expect(history.peak == 300)
        #expect(history.elapsed == 2)
    }

    @Test func aStallIsAZero() {
        var history = ThroughputHistory()
        history.add(at: 1, seconds: 1, bytes: 100, verifying: false)
        history.add(at: 6, seconds: 1, bytes: 100, verifying: false)
        #expect(history.bins.map(\.rate) == [100, 0, 0, 0, 0, 100])
    }

    /// A night of three hours stays as cheap to draw as a minute, and merging
    /// keeps the bytes: the average over the night is unchanged.
    @Test func aLongNightStaysSmall() {
        var history = ThroughputHistory()
        var total: Double = 0
        for second in 1...10_800 {
            let bytes = Int64(second % 7 * 1_000_000)
            total += Double(bytes)
            history.add(at: Double(second), seconds: 1, bytes: bytes, verifying: second > 7_000)
        }
        #expect(history.bins.count <= ThroughputHistory.maxBins)
        #expect(history.width == 64)
        #expect(history.bins.reduce(0) { $0 + $1.bytes } == total)
        #expect(history.bins.reduce(0) { $0 + $1.seconds } == 10_800)
        #expect(history.bins.last!.isVerifying)
        #expect(!history.bins.first!.isVerifying)
    }
}
