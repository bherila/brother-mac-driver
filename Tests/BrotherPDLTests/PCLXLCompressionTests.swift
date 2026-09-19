import Testing

@testable import BrotherPDL

/// SplitMix64, so a failing case is reproducible from its seed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func rleEncode(_ input: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    input.withUnsafeBytes { PCLXLRLE.encode($0, into: &output) }
    return output
}

private func randomBytes(count: Int, using generator: inout SplitMix64) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
}

/// Long runs of one value with occasional single-byte noise.
private func runHeavyBytes(count: Int, using generator: inout SplitMix64) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    while bytes.count < count {
        if Int.random(in: 0..<4, using: &generator) == 0 {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        } else {
            let value = UInt8.random(in: 0...255, using: &generator)
            let length = min(Int.random(in: 1...200, using: &generator), count - bytes.count)
            bytes.append(contentsOf: repeatElement(value, count: length))
        }
    }
    return Array(bytes.prefix(count))
}

private let sampleLengths = [0, 1, 2, 3, 127, 128, 129, 255, 256, 257, 1000]

@Suite struct PCLXLCompressionRLETests {
    @Test func encodesAShortRunAsOnePacket() {
        #expect(rleEncode([0xAA, 0xAA, 0xAA, 0xAA]) == [0xFD, 0xAA])
    }

    @Test func encodesDistinctBytesAsOneLiteral() {
        #expect(rleEncode([0x01, 0x02, 0x03]) == [0x02, 0x01, 0x02, 0x03])
    }

    @Test func encodesEmptyInputAsNothing() {
        #expect(rleEncode([]) == [])
    }

    @Test func encodesAMaximumLengthRun() {
        #expect(rleEncode([UInt8](repeating: 0, count: 128)) == [0x81, 0x00])
    }

    @Test func splitsARunLongerThanTheMaximumPacket() throws {
        let input = [UInt8](repeating: 0, count: 129)
        let encoded = rleEncode(input)
        #expect(encoded.count <= 4)
        #expect(try PCLXLRLE.decode(encoded) == input)
    }

    @Test func splitsAVeryLongRunIntoPacketsOf128() throws {
        let input = [UInt8](repeating: 0x5A, count: 300)
        #expect(rleEncode(input) == [0x81, 0x5A, 0x81, 0x5A, 0xD5, 0x5A])
        #expect(try PCLXLRLE.decode(rleEncode(input)) == input)
    }

    @Test func splitsLiteralsIntoPacketsOf128() throws {
        let input = (0..<300).map { UInt8($0 % 251) }
        let encoded = rleEncode(input)
        #expect(encoded.count == 303)
        #expect(encoded[0] == 127)
        #expect(encoded[129] == 127)
        #expect(encoded[258] == 43)
        #expect(try PCLXLRLE.decode(encoded) == input)
    }

    @Test func keepsATwoByteRunInsideALiteral() {
        #expect(rleEncode([0x01, 0x02, 0xAA, 0xAA, 0x03, 0x04]) == [0x05, 0x01, 0x02, 0xAA, 0xAA, 0x03, 0x04])
    }

    @Test func breaksALiteralForARunOfThree() {
        #expect(rleEncode([0x01, 0xAA, 0xAA, 0xAA, 0x02]) == [0x00, 0x01, 0xFE, 0xAA, 0x00, 0x02])
    }

    @Test func appendsToTheExistingOutput() {
        var output: [UInt8] = [0xEE]
        let input: [UInt8] = [0xAA, 0xAA, 0xAA, 0xAA]
        input.withUnsafeBytes { PCLXLRLE.encode($0, into: &output) }
        #expect(output == [0xEE, 0xFD, 0xAA])
    }

    @Test func neverReadsPastTheEndOfTheInput() {
        let buffer = [UInt8](repeating: 0xAA, count: 100)
        var output: [UInt8] = []
        buffer.withUnsafeBytes { bytes in
            PCLXLRLE.encode(UnsafeRawBufferPointer(rebasing: bytes[10..<20]), into: &output)
        }
        #expect(output == [0xF7, 0xAA])
    }

    @Test func concatenatedRowsDecodeAsOneStream() throws {
        var generator = SplitMix64(seed: 0x00C0_FFEE)
        let rows = (0..<8).map { _ in runHeavyBytes(count: 97, using: &generator) }
        var output: [UInt8] = []
        for row in rows {
            row.withUnsafeBytes { PCLXLRLE.encode($0, into: &output) }
        }
        #expect(try PCLXLRLE.decode(output) == rows.flatMap { $0 })
    }

    @Test func decodeSkipsTheNoOpControlByte() throws {
        #expect(try PCLXLRLE.decode([0x80, 0xFD, 0xAA]) == [0xAA, 0xAA, 0xAA, 0xAA])
    }

    @Test func decodeRejectsATruncatedLiteral() {
        #expect(throws: PCLXLError.truncated(offset: 0)) { try PCLXLRLE.decode([0x02, 0x01, 0x02]) }
    }

    @Test func decodeRejectsATruncatedRun() {
        #expect(throws: PCLXLError.truncated(offset: 0)) { try PCLXLRLE.decode([0xFD]) }
    }

    @Test func decodeReportsTheOffsetOfTheIncompletePacket() {
        #expect(throws: PCLXLError.truncated(offset: 2)) { try PCLXLRLE.decode([0xFD, 0xAA, 0x03, 0x01]) }
    }

    @Test(arguments: sampleLengths)
    func roundTripsRandomData(length: Int) throws {
        var generator = SplitMix64(seed: UInt64(length) &+ 0x5EED)
        let input = randomBytes(count: length, using: &generator)
        #expect(try PCLXLRLE.decode(rleEncode(input)) == input)
    }

    @Test(arguments: sampleLengths)
    func roundTripsRunHeavyData(length: Int) throws {
        var generator = SplitMix64(seed: UInt64(length) &+ 0xD15EA5E)
        let input = runHeavyBytes(count: length, using: &generator)
        #expect(try PCLXLRLE.decode(rleEncode(input)) == input)
    }

    @Test(arguments: sampleLengths)
    func roundTripsDegenerateData(length: Int) throws {
        let zeros = [UInt8](repeating: 0x00, count: length)
        let ones = [UInt8](repeating: 0xFF, count: length)
        let alternating = (0..<length).map { UInt8($0 % 2 == 0 ? 0x00 : 0xFF) }
        let pairs = (0..<length).map { UInt8(($0 / 2) % 2 == 0 ? 0x00 : 0xFF) }
        #expect(try PCLXLRLE.decode(rleEncode(zeros)) == zeros)
        #expect(try PCLXLRLE.decode(rleEncode(ones)) == ones)
        #expect(try PCLXLRLE.decode(rleEncode(alternating)) == alternating)
        #expect(try PCLXLRLE.decode(rleEncode(pairs)) == pairs)
    }

    @Test(arguments: sampleLengths)
    func neverExpandsByMoreThanOneBytePerPacket(length: Int) {
        var generator = SplitMix64(seed: UInt64(length) &+ 0xBADF00D)
        for _ in 0..<8 {
            let input = randomBytes(count: length, using: &generator)
            #expect(rleEncode(input).count <= length + (length + 127) / 128)
        }
    }
}

private func deltaEncode(_ rows: [[UInt8]], bytesPerRow: Int) -> [UInt8] {
    var codec = PCLXLDeltaRow(bytesPerRow: bytesPerRow)
    var output: [UInt8] = []
    for row in rows {
        row.withUnsafeBytes { codec.encode(row: $0, into: &output) }
    }
    return output
}

private func isMalformed(_ error: PCLXLError?) -> Bool {
    if let error, case .malformed = error { return true }
    return false
}

@Suite struct PCLXLCompressionDeltaRowTests {
    @Test func encodesAnUnchangedRowAsAnEmptyBlock() {
        #expect(deltaEncode([[0x00, 0x00, 0x00, 0x00]], bytesPerRow: 4) == [0x00, 0x00])
    }

    @Test func encodesASingleChangedByte() {
        #expect(deltaEncode([[0x00, 0xFF, 0x00, 0x00]], bytesPerRow: 4) == [0x02, 0x00, 0x01, 0xFF])
    }

    @Test func encodesAFullyChangedRow() {
        #expect(deltaEncode([[0x11, 0x22, 0x33, 0x44]], bytesPerRow: 4) == [0x05, 0x00, 0x60, 0x11, 0x22, 0x33, 0x44])
    }

    @Test func encodesAnOffsetThatNeedsAnExtraByte() {
        var row = [UInt8](repeating: 0, count: 40)
        row[35] = 0x7E
        #expect(deltaEncode([row], bytesPerRow: 40) == [0x03, 0x00, 0x1F, 0x04, 0x7E])
    }

    @Test func encodesAnOffsetOfExactly31WithAZeroExtraByte() {
        var row = [UInt8](repeating: 0, count: 40)
        row[31] = 0x55
        #expect(deltaEncode([row], bytesPerRow: 40) == [0x03, 0x00, 0x1F, 0x00, 0x55])
    }

    @Test func encodesAnOffsetThatNeedsAContinuationByte() {
        var row = [UInt8](repeating: 0, count: 300)
        row[286] = 0x99
        #expect(deltaEncode([row], bytesPerRow: 300) == [0x04, 0x00, 0x1F, 0xFF, 0x00, 0x99])
    }

    @Test func encodesAnIdenticalSecondRowAsAnEmptyBlock() {
        let row: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let encoded = deltaEncode([row, row], bytesPerRow: 4)
        #expect(Array(encoded.suffix(2)) == [0x00, 0x00])
    }

    @Test func splitsASpanLongerThanEightBytesIntoConsecutiveCommands() {
        var row = [UInt8](repeating: 0, count: 20)
        for index in 0..<9 { row[index] = UInt8(index + 1) }
        let expected: [UInt8] =
            [0x0B, 0x00, 0xE0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00, 0x09]
        #expect(deltaEncode([row], bytesPerRow: 20) == expected)
    }

    @Test func resetRestoresTheZeroSeedRow() {
        var codec = PCLXLDeltaRow(bytesPerRow: 16)
        let first: [UInt8] = (0..<16).map { UInt8($0 * 7 % 256) }
        var initial: [UInt8] = []
        first.withUnsafeBytes { codec.encode(row: $0, into: &initial) }

        var noise: [UInt8] = []
        [UInt8](repeating: 0xC3, count: 16).withUnsafeBytes { codec.encode(row: $0, into: &noise) }

        codec.reset()
        var again: [UInt8] = []
        first.withUnsafeBytes { codec.encode(row: $0, into: &again) }
        #expect(again == initial)
    }

    @Test func decodeRejectsAMissingRowCount() {
        #expect(throws: PCLXLError.truncated(offset: 0)) {
            try PCLXLDeltaRow.decode([0x00], bytesPerRow: 4, rowCount: 1)
        }
    }

    @Test func decodeRejectsATruncatedRowBlock() {
        #expect(throws: PCLXLError.truncated(offset: 2)) {
            try PCLXLDeltaRow.decode([0x02, 0x00, 0x01], bytesPerRow: 4, rowCount: 1)
        }
    }

    @Test func decodeRejectsACommandThatWritesPastTheRow() {
        let error = #expect(throws: PCLXLError.self) {
            try PCLXLDeltaRow.decode([0x03, 0x00, 0x1F, 0x05, 0xAA], bytesPerRow: 2, rowCount: 1)
        }
        #expect(isMalformed(error))
    }

    @Test func decodeRejectsACommandCutOffByTheRowCount() {
        let error = #expect(throws: PCLXLError.self) {
            try PCLXLDeltaRow.decode([0x02, 0x00, 0x60, 0x11], bytesPerRow: 4, rowCount: 1)
        }
        #expect(isMalformed(error))
    }

    @Test func decodeRejectsTrailingBytes() {
        let error = #expect(throws: PCLXLError.self) {
            try PCLXLDeltaRow.decode([0x00, 0x00, 0x00], bytesPerRow: 4, rowCount: 1)
        }
        #expect(isMalformed(error))
    }

    @Test func decodeReturnsZeroRowsForAnEmptyBlock() throws {
        #expect(try PCLXLDeltaRow.decode([], bytesPerRow: 4, rowCount: 0) == [])
    }

    @Test(arguments: [1, 31, 32, 33, 286, 287, 600, 15300])
    func roundTripsRandomRows(bytesPerRow: Int) throws {
        var generator = SplitMix64(seed: UInt64(bytesPerRow) &+ 0xA11CE)
        let rows = (0..<12).map { _ in randomBytes(count: bytesPerRow, using: &generator) }
        let encoded = deltaEncode(rows, bytesPerRow: bytesPerRow)
        #expect(try PCLXLDeltaRow.decode(encoded, bytesPerRow: bytesPerRow, rowCount: rows.count) == rows.flatMap { $0 })
    }

    @Test(arguments: [1, 31, 32, 33, 286, 287, 600, 15300])
    func roundTripsSparselyChangingRows(bytesPerRow: Int) throws {
        var generator = SplitMix64(seed: UInt64(bytesPerRow) &+ 0xB0B)
        var previous = [UInt8](repeating: 0, count: bytesPerRow)
        var rows: [[UInt8]] = []
        for _ in 0..<16 {
            var row = previous
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                let start = Int.random(in: 0..<bytesPerRow, using: &generator)
                let length = min(Int.random(in: 1...20, using: &generator), bytesPerRow - start)
                for index in start..<(start + length) {
                    row[index] = UInt8.random(in: 0...255, using: &generator)
                }
            }
            rows.append(row)
            previous = row
        }
        let encoded = deltaEncode(rows, bytesPerRow: bytesPerRow)
        #expect(try PCLXLDeltaRow.decode(encoded, bytesPerRow: bytesPerRow, rowCount: rows.count) == rows.flatMap { $0 })
    }

    @Test(arguments: [1, 7, 8, 9, 16, 17])
    func roundTripsChangedSpansAtEveryEdge(spanLength: Int) throws {
        for bytesPerRow in [1, 31, 32, 33, 287, 600] where bytesPerRow >= spanLength {
            let seed = [UInt8](repeating: 0x40, count: bytesPerRow)
            var rows: [[UInt8]] = [seed]
            for start in [0, bytesPerRow - spanLength, max(0, (bytesPerRow - spanLength) / 2)] {
                var row = rows[rows.count - 1]
                for index in start..<(start + spanLength) { row[index] = UInt8(index % 256) &+ 0x80 }
                rows.append(row)
            }
            rows.append(rows[rows.count - 1])
            rows.append([UInt8](repeating: 0xFF, count: bytesPerRow))
            let encoded = deltaEncode(rows, bytesPerRow: bytesPerRow)
            let decoded = try PCLXLDeltaRow.decode(encoded, bytesPerRow: bytesPerRow, rowCount: rows.count)
            #expect(decoded == rows.flatMap { $0 })
        }
    }

    @Test func roundTripsAlternatingAndUniformRows() throws {
        let bytesPerRow = 601
        let rows: [[UInt8]] = [
            [UInt8](repeating: 0x00, count: bytesPerRow),
            [UInt8](repeating: 0xFF, count: bytesPerRow),
            (0..<bytesPerRow).map { UInt8($0 % 2 == 0 ? 0x00 : 0xFF) },
            (0..<bytesPerRow).map { UInt8($0 % 2 == 0 ? 0xFF : 0x00) },
            [UInt8](repeating: 0xFF, count: bytesPerRow),
        ]
        let encoded = deltaEncode(rows, bytesPerRow: bytesPerRow)
        #expect(try PCLXLDeltaRow.decode(encoded, bytesPerRow: bytesPerRow, rowCount: rows.count) == rows.flatMap { $0 })
    }

    @Test func appendsToTheExistingOutput() {
        var codec = PCLXLDeltaRow(bytesPerRow: 4)
        var output: [UInt8] = [0xEE]
        [UInt8]([0x00, 0xFF, 0x00, 0x00]).withUnsafeBytes { codec.encode(row: $0, into: &output) }
        #expect(output == [0xEE, 0x02, 0x00, 0x01, 0xFF])
    }
}
