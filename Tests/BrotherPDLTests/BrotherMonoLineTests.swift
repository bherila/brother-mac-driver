import Testing

@testable import BrotherPDL

@Suite struct BrotherMonoLineTests {
    private func encode(_ line: [UInt8], reference: [UInt8]? = nil) -> [UInt8] {
        var output: [UInt8] = []
        line.withUnsafeBufferPointer { line in
            if let reference {
                reference.withUnsafeBufferPointer { BrotherMonoLine.encode(line, reference: $0, into: &output) }
            } else {
                BrotherMonoLine.encode(line, reference: nil, into: &output)
            }
        }
        return output
    }

    private func decode(_ encoded: [UInt8], reference: [UInt8]) throws -> [UInt8] {
        var index = 0
        var line = reference
        try BrotherMonoLine.decode(encoded, at: &index, onto: &line)
        #expect(index == encoded.count, "decoder did not consume the whole line")
        return line
    }

    // MARK: Hand-derived vectors

    @Test func blankLineIsOneByte() {
        #expect(encode([0, 0, 0, 0]) == [0xFF])
        #expect(encode([0, 0, 0, 0], reference: [9, 9, 9, 9]) == [0xFF])
    }

    @Test func standaloneLineIsOneSubstitute() {
        // 1 edit; substitute offset 0, count-1 = 3 → 0b0_0000_011.
        #expect(encode([0x11, 0x22, 0x33, 0x44]) == [1, 0x03, 0x11, 0x22, 0x33, 0x44])
    }

    @Test func standaloneLongLineUsesCountOverflow() {
        // 10 bytes: count-1 = 9 → field 7, overflow 2.
        let line: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(encode(line) == [1, 0x07, 2] + line)
    }

    @Test func identicalToReferenceIsZeroEdits() {
        #expect(encode([5, 6, 7], reference: [5, 6, 7]) == [0])
    }

    @Test func singleChangedByte() {
        // substitute, offset 2, count-1 = 0 → 0b0_0010_000.
        #expect(encode([1, 2, 9, 4], reference: [1, 2, 3, 4]) == [1, 0x10, 9])
    }

    @Test func runBecomesRepeat() {
        // repeat, offset 1, count-2 = 3 → 0b1_01_00011.
        #expect(encode([0, 7, 7, 7, 7, 7, 0, 0], reference: [UInt8](repeating: 0, count: 8)) == [1, 0xA3, 7])
    }

    @Test func offsetOverflow() {
        // Offset 20 into a substitute: field 15, overflow 5. Offset 20 into a repeat: field 3, overflow 17.
        var line = [UInt8](repeating: 0, count: 40)
        line[20] = 0x5A
        #expect(encode(line, reference: [UInt8](repeating: 0, count: 40)) == [1, 0x78, 5, 0x5A])
        line[21] = 0x5A
        line[22] = 0x5A
        #expect(encode(line, reference: [UInt8](repeating: 0, count: 40)) == [1, 0xE1, 17, 0x5A])
    }

    @Test func fieldExactlyAtMaximumWritesZeroOverflow() {
        var line = [UInt8](repeating: 0, count: 40)
        line[15] = 1
        #expect(encode(line, reference: [UInt8](repeating: 0, count: 40)) == [1, 0x78, 0, 1])
    }

    // MARK: Round trips

    private struct Generator {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
    }

    /// A line that looks like halftoned print: mostly the reference, with runs, noise and gaps.
    private func mutate(_ reference: [UInt8], _ generator: inout Generator) -> [UInt8] {
        var line = reference
        for _ in 0..<generator.next() % 12 {
            let start = generator.next() % line.count
            let length = min(line.count - start, 1 + generator.next() % 300)
            let kind = generator.next() % 3
            let value = UInt8(truncatingIfNeeded: generator.next())
            for position in start..<start + length {
                line[position] = kind == 0 ? value : kind == 1 ? UInt8(truncatingIfNeeded: generator.next()) : 0
            }
        }
        return line
    }

    @Test(arguments: [1, 2, 3, 15, 16, 17, 255, 256, 600, 613])
    func roundTripsAgainstReference(width: Int) throws {
        var generator = Generator(state: UInt64(width))
        var reference = [UInt8](repeating: 0, count: width)
        for _ in 0..<200 {
            let line = mutate(reference, &generator)
            #expect(try decode(encode(line, reference: reference), reference: reference) == line)
            #expect(try decode(encode(line), reference: [UInt8](repeating: 0xEE, count: width)) == line)
            reference = line
        }
    }

    @Test func runsOutOfEditsGracefully() throws {
        // Alternate changed/unchanged pairs so every change needs its own edit: far more than 254.
        let width = 4000
        let reference = [UInt8](repeating: 0, count: width)
        let line = (0..<width).map { UInt8($0 % 4 == 0 ? 0x81 : 0) }
        let encoded = encode(line, reference: reference)
        #expect(encoded[0] == UInt8(BrotherMonoLine.maxEdits))
        #expect(try decode(encoded, reference: reference) == line)
    }

    @Test func truncatedInputThrows() {
        var index = 0
        var line = [UInt8](repeating: 0, count: 4)
        #expect(throws: PCLXLError.self) {
            try BrotherMonoLine.decode([1, 0x03, 0x11], at: &index, onto: &line)
        }
    }
}
