import Testing

@testable import BrotherPDL

@Suite struct BufferedSinkTests {
    final class Collector {
        var bytes: [UInt8] = []
        var blocks: [Int] = []
    }

    /// Writes a counting byte pattern in the given chunk sizes and returns what reached downstream.
    private func push(_ sizes: [Int], limit: Int) throws -> (collector: Collector, expected: [UInt8]) {
        let collector = Collector()
        var sink = BufferedSink(limit: limit) {
            collector.bytes.append(contentsOf: $0)
            collector.blocks.append($0.count)
        }
        var expected: [UInt8] = []
        var next: UInt8 = 0
        for size in sizes {
            let chunk = (0..<size).map { _ -> UInt8 in
                next &+= 1
                return next
            }
            expected += chunk
            try sink.write(chunk)
        }
        try sink.flush()
        #expect(sink.bytesWritten == expected.count)
        return (collector, expected)
    }

    /// The failure this guards against: a small header is buffered, then a large data block goes
    /// straight downstream ahead of it. Sizes straddle the limit on both sides.
    @Test(arguments: [15, 16, 17, 31, 32, 33, 100])
    func smallThenLargeKeepsOrder(large: Int) throws {
        let (collector, expected) = try push([5, large, 1, 7, large, 1], limit: 16)
        #expect(collector.bytes == expected)
    }

    @Test func orderHoldsForArbitraryWriteSizes() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let sizes = (0..<2000).map { _ -> Int in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let roll = Int(truncatingIfNeeded: state >> 40) & 0xFFFF
            // Mostly tiny writes, with writes around and well above the limit mixed in.
            return roll % 7 == 0 ? 200 + roll % 900 : roll % 40
        }
        let (collector, expected) = try push(sizes, limit: 256)
        #expect(collector.bytes == expected)
    }

    @Test func smallWritesAreCoalescedAndNothingExceedsTheLimitUnlessWrittenWhole() throws {
        let (collector, _) = try push([Int](repeating: 3, count: 100), limit: 64)
        #expect(collector.blocks.count < 10)
        #expect(collector.blocks.allSatisfy { $0 <= 64 })

        let (large, _) = try push([3, 500, 3], limit: 64)
        #expect(large.blocks == [3, 500, 3])
    }

    @Test func flushOfEmptyBufferSendsNothing() throws {
        let (collector, _) = try push([], limit: 64)
        #expect(collector.blocks.isEmpty)
    }
}
