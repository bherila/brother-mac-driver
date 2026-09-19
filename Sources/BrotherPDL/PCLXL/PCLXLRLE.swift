/// PCL XL `eRLECompression`.
///
/// A byte stream of packets. Control byte `c`:
/// - `0...127`   → the next `c + 1` bytes are literals
/// - `129...255` → the next single byte is repeated `257 - c` times (2...128)
/// - `128`       → no-op, skipped
public enum PCLXLRLE {
    /// Appends the encoding of `input` to `output`. Runs never extend past the end of `input`,
    /// so callers can encode row by row and concatenate.
    public static func encode(_ input: UnsafeRawBufferPointer, into output: inout [UInt8]) {
        let count = input.count
        guard count > 0 else { return }
        let bytes = input.bindMemory(to: UInt8.self)
        output.reserveCapacity(output.count + count + (count + 127) / 128)

        var index = 0
        while index < count {
            // Literals, absorbing runs of one or two bytes: breaking a literal to encode a
            // two-byte run costs one control byte more than leaving the pair in place.
            let literalStart = index
            var end = index
            while end < count {
                let run = runLength(bytes, from: end, count: count, limit: 3)
                if run >= 3 { break }
                if end + run - literalStart > 128 { break }
                end += run
            }
            if end > literalStart {
                output.append(UInt8(end - literalStart - 1))
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[literalStart..<end]))
            }
            index = end

            // Runs of three or more, split into packets of at most 128 bytes.
            while index < count {
                let run = runLength(bytes, from: index, count: count, limit: 128)
                if run < 3 { break }
                output.append(UInt8(257 - run))
                output.append(bytes[index])
                index += run
            }
        }
    }

    /// Decodes a complete RLE stream. Throws `PCLXLError.truncated` if a packet is cut short,
    /// with the offset of that packet's control byte.
    public static func decode(_ input: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        try input.withUnsafeBufferPointer { bytes in
            var index = 0
            while index < bytes.count {
                let control = Int(bytes[index])
                let packet = index
                index += 1
                if control < 128 {
                    let length = control + 1
                    guard index + length <= bytes.count else { throw PCLXLError.truncated(offset: packet) }
                    output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index..<index + length]))
                    index += length
                } else if control > 128 {
                    guard index < bytes.count else { throw PCLXLError.truncated(offset: packet) }
                    output.append(contentsOf: repeatElement(bytes[index], count: 257 - control))
                    index += 1
                }
            }
        }
        return output
    }

    /// The number of equal bytes starting at `index`, counting no further than `limit`.
    @inline(__always)
    private static func runLength(
        _ bytes: UnsafeBufferPointer<UInt8>, from index: Int, count: Int, limit: Int
    ) -> Int {
        let value = bytes[index]
        let end = min(count, index + limit)
        var next = index + 1
        while next < end && bytes[next] == value { next += 1 }
        return next - index
    }
}
