public enum PCLXLError: Error, Equatable, Sendable {
    /// Compressed or stream data ended before a complete element was read.
    case truncated(offset: Int)
    /// A byte that is not a valid tag at this position.
    case unexpectedTag(UInt8, offset: Int)
    /// Structurally valid but semantically wrong (missing attribute, size mismatch, …).
    case malformed(String)
    /// Valid PCL XL that this implementation does not handle.
    case unsupported(String)
}

extension PCLXLError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .truncated(let offset): "data ended early at offset \(offset)"
        case .unexpectedTag(let tag, let offset): "unexpected byte 0x\(String(tag, radix: 16)) at offset \(offset)"
        case .malformed(let reason): "malformed data: \(reason)"
        case .unsupported(let reason): reason
        }
    }
}
