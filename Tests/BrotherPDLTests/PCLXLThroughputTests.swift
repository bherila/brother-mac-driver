import Foundation
import Testing

@testable import BrotherPDL

/// Opt-in: `BROTHER_PERF=1 swift test -c release --filter Throughput`.
/// A US Letter page at 600 dpi is 5100 × 6600 RGB, about 100 MB per page.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BROTHER_PERF"] != nil))
struct PCLXLThroughputTests {
    struct DiscardingSink: ByteSink {
        var count = 0
        mutating func write(_ bytes: UnsafeRawBufferPointer) throws { count += bytes.count }
    }

    /// Text-like stripes, a noisy photo block and a flat colour block.
    static func letterRows() -> [[UInt8]] {
        let width = 5100
        var state: UInt64 = 1
        var text = [UInt8](repeating: 0xFF, count: width * 3)
        for x in stride(from: 600, to: 4500, by: 7) { for c in 0..<9 { text[x * 3 + c] = 0 } }
        var photo = [UInt8](repeating: 0xFF, count: width * 3)
        for i in 600 * 3..<3000 * 3 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            photo[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        var flat = [UInt8](repeating: 0xFF, count: width * 3)
        for x in 1000..<4000 { flat[x * 3] = 0x20; flat[x * 3 + 1] = 0x60; flat[x * 3 + 2] = 0xC0 }
        let white = [UInt8](repeating: 0xFF, count: width * 3)
        return [white, text, photo, flat]
    }

    @Test(arguments: [JobOptions.Compression.rle, .deltaRow])
    func letterPage(compression: JobOptions.Compression) throws {
        let rows = Self.letterRows()
        var options = JobOptions()
        options.compression = compression
        var backend = PCLXLBackend(options: options)
        var sink = DiscardingSink()

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            try backend.beginJob(to: &sink)
            try backend.beginPage(PageGeometry(width: 5100, height: 6600, dpi: 600, format: .rgb8), to: &sink)
            for y in 0..<6600 {
                // Top margin, text, photo, flat colour, text, bottom margin.
                let kind = switch y {
                case ..<300, 6300...: 0
                case 300..<2500: y % 100 < 60 ? 1 : 0
                case 2500..<4000: 2
                case 4000..<4800: 3
                default: y % 100 < 60 ? 1 : 0
                }
                try rows[kind].withUnsafeBytes { try backend.writeRow($0, to: &sink) }
            }
            try backend.endPage(to: &sink)
            try backend.endJob(to: &sink)
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("\(compression): \(sink.count / 1024) KiB in \(String(format: "%.2f", seconds)) s")
        #expect(seconds < 5, "a Letter page should encode in a few seconds at most")
    }
}
