/// A decoded PCL XL attribute value. Integer types are widened; `real32` is kept as `Float`.
public enum PCLXLValue: Equatable, Sendable {
    case integer(Int)
    case real(Float)
    case integers([Int])
    case reals([Float])
    case bytes([UInt8])

    /// The single integer, or nil for any other shape.
    public var intValue: Int? {
        if case .integer(let value) = self { value } else { nil }
    }

    /// The integers of an xy (2), box (4) or array value, or nil for any other shape.
    public var intArray: [Int]? {
        if case .integers(let values) = self { values } else { nil }
    }
}

/// One operator with the attribute list that preceded it and any embedded data that followed it.
public struct PCLXLOperatorRecord: Equatable, Sendable {
    /// Raw operator tag. Use `PCLXLOperator(rawValue:)` for the ones this project names.
    public var tag: UInt8
    /// Attribute id → value, in stream order.
    public var attributes: [(id: UInt8, value: PCLXLValue)]
    /// Embedded data (`0xFA` / `0xFB` block) that followed the operator, if any.
    public var data: [UInt8]?
    /// Byte offset of the operator tag from the start of the input.
    public var offset: Int

    public init(tag: UInt8, attributes: [(id: UInt8, value: PCLXLValue)], data: [UInt8]?, offset: Int) {
        self.tag = tag
        self.attributes = attributes
        self.data = data
        self.offset = offset
    }

    public subscript(attribute: PCLXLAttribute) -> PCLXLValue? {
        attributes.first { $0.id == attribute.rawValue }?.value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.data == rhs.data && lhs.offset == rhs.offset
            && lhs.attributes.count == rhs.attributes.count
            && zip(lhs.attributes, rhs.attributes).allSatisfy { $0.id == $1.id && $0.value == $1.value }
    }
}

/// A whole print job: optional PJL wrapper, the PCL XL stream header line, and the operators.
public struct PCLXLStream: Equatable, Sendable {
    /// `@PJL …` lines before the stream header, without line terminators. Empty if there is no PJL wrapper.
    public var pjlHeader: [String]
    /// The header line, e.g. `) HP-PCL XL;2;0;Comment`, without its terminating newline.
    public var streamHeader: String
    public var operators: [PCLXLOperatorRecord]
    /// `@PJL …` lines after the trailing UEL, without line terminators.
    public var pjlTrailer: [String]

    public init(pjlHeader: [String], streamHeader: String, operators: [PCLXLOperatorRecord], pjlTrailer: [String]) {
        self.pjlHeader = pjlHeader
        self.streamHeader = streamHeader
        self.operators = operators
        self.pjlTrailer = pjlTrailer
    }
}

public enum PCLXLReader {
    /// Parses a complete job. Only the little-endian binary binding (`)`) is supported.
    public static func parse(_ bytes: [UInt8]) throws -> PCLXLStream {
        throw PCLXLError.unsupported("reader unimplemented")
    }
}
