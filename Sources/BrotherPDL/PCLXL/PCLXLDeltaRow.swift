/// PCL XL `eDeltaRowCompression` (protocol class 2.1).
///
/// Each row is a 2-byte little-endian byte count followed by that many bytes of PCL "mode 3"
/// delta data relative to the previous row. The seed row is all zeros at the start of every
/// ReadImage block. Rows are not padded.
///
/// Delta data is a sequence of commands. Command byte: the top 3 bits are
/// `(replacement count - 1)` (1...8 bytes); the low 5 bits are the offset from the current
/// position to the first byte replaced. An offset field of 31 means additional offset bytes
/// follow, each added to the offset, continuing while the byte just read is 255. The
/// replacement bytes follow. After a command the current position is just past the last
/// replaced byte. Bytes not covered by any command are unchanged from the seed row.
public struct PCLXLDeltaRow: Sendable {
    public let bytesPerRow: Int

    /// The previous row, which the next `encode(row:into:)` is expressed against.
    private var seed: [UInt8]

    public init(bytesPerRow: Int) {
        self.bytesPerRow = bytesPerRow
        self.seed = [UInt8](repeating: 0, count: bytesPerRow)
    }

    /// Resets the seed row to zeros. Call at the start of each ReadImage block.
    public mutating func reset() {
        seed.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    /// Appends `row` (exactly `bytesPerRow` bytes) to `output` as count + delta data, then makes it the seed row.
    public mutating func encode(row: UnsafeRawBufferPointer, into output: inout [UInt8]) {
        precondition(row.count == bytesPerRow, "row must be exactly bytesPerRow bytes")
        let width = bytesPerRow
        let countIndex = output.count
        output.append(0)
        output.append(0)

        let source = row.bindMemory(to: UInt8.self)
        seed.withUnsafeMutableBufferPointer { seed in
            var position = 0
            var index = 0
            while let start = Self.nextDifference(source, seed, from: index, count: width) {
                var end = start + 1
                while end < width && source[end] != seed[end] { end += 1 }

                var chunk = start
                var offset = start - position
                while chunk < end {
                    let length = min(end - chunk, 8)
                    Self.appendCommand(&output, replacements: length, offset: offset)
                    output.append(contentsOf: UnsafeBufferPointer(rebasing: source[chunk..<chunk + length]))
                    chunk += length
                    offset = 0
                }
                position = end
                index = end
            }
            if let destination = seed.baseAddress, let updated = source.baseAddress {
                destination.update(from: updated, count: width)
            }
        }

        let length = output.count - countIndex - 2
        output[countIndex] = UInt8(length & 0xFF)
        output[countIndex + 1] = UInt8((length >> 8) & 0xFF)
    }

    /// Decodes one ReadImage block of `rowCount` rows into `rowCount * bytesPerRow` bytes.
    public static func decode(_ input: [UInt8], bytesPerRow: Int, rowCount: Int) throws -> [UInt8] {
        var seed = [UInt8](repeating: 0, count: bytesPerRow)
        var output: [UInt8] = []
        output.reserveCapacity(bytesPerRow * rowCount)

        var cursor = 0
        for _ in 0..<rowCount {
            guard cursor + 2 <= input.count else { throw PCLXLError.truncated(offset: cursor) }
            let length = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard cursor + length <= input.count else { throw PCLXLError.truncated(offset: cursor) }

            let end = cursor + length
            var index = cursor
            var position = 0
            while index < end {
                let command = Int(input[index])
                index += 1
                let replacements = (command >> 5) + 1
                var offset = command & 31
                if offset == 31 {
                    while true {
                        guard index < end else {
                            throw PCLXLError.malformed("delta row offset ends inside row at \(cursor)")
                        }
                        let extra = Int(input[index])
                        index += 1
                        offset += extra
                        if extra != 255 { break }
                    }
                }
                position += offset
                guard position + replacements <= bytesPerRow else {
                    throw PCLXLError.malformed("delta row command writes past the end of the row at \(cursor)")
                }
                guard index + replacements <= end else {
                    throw PCLXLError.malformed("delta row command ends inside row at \(cursor)")
                }
                for step in 0..<replacements { seed[position + step] = input[index + step] }
                index += replacements
                position += replacements
            }

            cursor = end
            output.append(contentsOf: seed)
        }

        guard cursor == input.count else {
            throw PCLXLError.malformed("\(input.count - cursor) bytes left after \(rowCount) rows")
        }
        return output
    }

    /// The first index at or after `from` where the row differs from the seed, eight bytes at a time.
    @inline(__always)
    private static func nextDifference(
        _ row: UnsafeBufferPointer<UInt8>, _ seed: UnsafeMutableBufferPointer<UInt8>,
        from index: Int, count: Int
    ) -> Int? {
        guard let rowBase = row.baseAddress, let seedBase = seed.baseAddress else { return nil }
        var next = index
        while next + 8 <= count {
            let left = UnsafeRawPointer(rowBase + next).loadUnaligned(as: UInt64.self)
            let right = UnsafeRawPointer(seedBase + next).loadUnaligned(as: UInt64.self)
            if left != right { break }
            next += 8
        }
        while next < count {
            if row[next] != seed[next] { return next }
            next += 1
        }
        return nil
    }

    /// Emits a command byte plus any extra offset bytes an offset of 31 or more needs.
    @inline(__always)
    private static func appendCommand(_ output: inout [UInt8], replacements: Int, offset: Int) {
        let high = UInt8(replacements - 1) << 5
        guard offset >= 31 else {
            output.append(high | UInt8(offset))
            return
        }
        output.append(high | 31)
        var remaining = offset - 31
        while true {
            let part = min(remaining, 255)
            output.append(UInt8(part))
            remaining -= part
            if part != 255 { break }
        }
    }
}
