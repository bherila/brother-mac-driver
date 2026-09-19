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

    public init(bytesPerRow: Int) {
        self.bytesPerRow = bytesPerRow
    }

    /// Resets the seed row to zeros. Call at the start of each ReadImage block.
    public mutating func reset() {
        fatalError("unimplemented")
    }

    /// Appends `row` (exactly `bytesPerRow` bytes) to `output` as count + delta data, then makes it the seed row.
    public mutating func encode(row: UnsafeRawBufferPointer, into output: inout [UInt8]) {
        fatalError("unimplemented")
    }

    /// Decodes one ReadImage block of `rowCount` rows into `rowCount * bytesPerRow` bytes.
    public static func decode(_ input: [UInt8], bytesPerRow: Int, rowCount: Int) throws -> [UInt8] {
        throw PCLXLError.unsupported("DeltaRow decode unimplemented")
    }
}
