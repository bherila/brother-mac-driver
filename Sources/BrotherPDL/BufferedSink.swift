/// Coalesces small writes into blocks of up to `limit` bytes before handing them downstream.
///
/// Byte order is the invariant: a write of `limit` bytes or more bypasses the buffer, so the
/// buffer is always emptied first. The decision uses `limit`, never the array's capacity, which
/// the runtime is free to round up.
public struct BufferedSink: ByteSink {
    public let limit: Int
    public private(set) var bytesWritten = 0
    private var buffer: [UInt8] = []
    private let downstream: (UnsafeRawBufferPointer) throws -> Void

    public init(limit: Int = 1 << 16, downstream: @escaping (UnsafeRawBufferPointer) throws -> Void) {
        precondition(limit > 0)
        self.limit = limit
        self.downstream = downstream
        buffer.reserveCapacity(limit)
    }

    public mutating func write(_ bytes: UnsafeRawBufferPointer) throws {
        if buffer.count + bytes.count > limit {
            try flush()
        }
        if bytes.count >= limit {
            try downstream(bytes)
        } else {
            buffer.append(contentsOf: bytes)
        }
        bytesWritten += bytes.count
    }

    public mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBytes { try downstream($0) }
        buffer.removeAll(keepingCapacity: true)
    }
}
