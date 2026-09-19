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
        fatalError("unimplemented")
    }

    /// Decodes a complete RLE stream. Throws `PCLXLError.truncated` if a packet is cut short.
    public static func decode(_ input: [UInt8]) throws -> [UInt8] {
        throw PCLXLError.unsupported("RLE decode unimplemented")
    }
}
