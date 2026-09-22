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

/// One attribute of an operator: the value, the data tag it was written with, and where it started.
///
/// The tag is kept because the value alone cannot tell a `ubyte` from a `uint16`, and a printer
/// rejects an attribute sent with a data type it does not accept for that attribute.
public struct PCLXLAttributeRecord: Equatable, Sendable {
    public var id: UInt8
    public var value: PCLXLValue
    /// The data tag that introduced the value.
    public var tag: PCLXLDataTag
    /// Byte offset of the data tag from the start of the input.
    public var offset: Int

    public init(id: UInt8, value: PCLXLValue, tag: PCLXLDataTag, offset: Int) {
        self.id = id
        self.value = value
        self.tag = tag
        self.offset = offset
    }

    /// The named attribute, or nil for an id this project does not name.
    public var attribute: PCLXLAttribute? { PCLXLAttribute(rawValue: id) }
}

/// One operator with the attribute list that preceded it and any embedded data that followed it.
public struct PCLXLOperatorRecord: Equatable, Sendable {
    /// Raw operator tag. Use `PCLXLOperator(rawValue:)` for the ones this project names.
    public var tag: UInt8
    /// The attributes that preceded the operator, in stream order.
    public var attributes: [PCLXLAttributeRecord]
    /// Embedded data (`0xFA` / `0xFB` block) that followed the operator, if any.
    public var data: [UInt8]?
    /// Byte offset of the operator tag from the start of the input.
    public var offset: Int

    public init(tag: UInt8, attributes: [PCLXLAttributeRecord], data: [UInt8]?, offset: Int) {
        self.tag = tag
        self.attributes = attributes
        self.data = data
        self.offset = offset
    }

    public subscript(attribute: PCLXLAttribute) -> PCLXLValue? {
        attributes.first { $0.id == attribute.rawValue }?.value
    }

    /// Two records are equal when they carry the same attribute ids and values; the data tags and
    /// attribute offsets are reporting detail, not part of the record's identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.data == rhs.data && lhs.offset == rhs.offset
            && lhs.attributes.count == rhs.attributes.count
            && zip(lhs.attributes, rhs.attributes).allSatisfy { $0.id == $1.id && $0.value == $1.value }
    }

    /// The record for a named attribute, with its data tag and offset.
    public func record(_ attribute: PCLXLAttribute) -> PCLXLAttributeRecord? {
        attributes.first { $0.id == attribute.rawValue }
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
    /// The universal exit language escape: `ESC %-12345X`.
    public static let uel: [UInt8] = [0x1B, 0x25, 0x2D, 0x31, 0x32, 0x33, 0x34, 0x35, 0x58]

    /// Parses a complete job. Only the little-endian binary binding (`)`) is supported.
    public static func parse(_ bytes: [UInt8]) throws -> PCLXLStream {
        var scanner = Scanner(bytes: bytes)
        let pjlHeader = try scanner.readPJLBlock()
        let streamHeader = try scanner.readStreamHeaderLine()
        var operators: [PCLXLOperatorRecord] = []
        var pending: [PCLXLAttributeRecord] = []

        while true {
            scanner.skipWhiteSpace()
            guard let tag = scanner.peek() else {
                guard pending.isEmpty else {
                    throw PCLXLError.malformed("\(pending.count) attribute(s) at the end of the stream have no operator")
                }
                break
            }
            if tag == 0x1B {
                guard scanner.matches(uel) else { throw PCLXLError.unexpectedTag(tag, offset: scanner.offset) }
                guard pending.isEmpty else {
                    throw PCLXLError.malformed(
                        "\(pending.count) attribute(s) before the closing UEL at offset \(scanner.offset) have no operator")
                }
                scanner.advance(by: uel.count)
                break
            }
            switch tag {
            case 0xC0...0xE5:
                let valueOffset = scanner.offset
                let (dataTag, value) = try scanner.readValue()
                scanner.skipWhiteSpace()
                pending.append(
                    PCLXLAttributeRecord(
                        id: try scanner.readAttributeID(), value: value, tag: dataTag, offset: valueOffset))
            case 0x41...0xBF:
                let offset = scanner.offset
                scanner.advance(by: 1)
                let data = try scanner.readEmbeddedData()
                operators.append(
                    PCLXLOperatorRecord(tag: tag, attributes: pending, data: data, offset: offset))
                pending = []
            default:
                throw PCLXLError.unexpectedTag(tag, offset: scanner.offset)
            }
        }

        let pjlTrailer = try scanner.readTrailingPJL()
        // The trailer stops at the first thing that is neither PJL nor a UEL. Returning anyway
        // would hide whatever follows — a second job concatenated on, or a corrupted tail — which
        // the printer still reads even though nothing here described it.
        guard scanner.isAtEnd else {
            throw PCLXLError.malformed("\(scanner.remaining) byte(s) after the end of the job at offset \(scanner.offset)")
        }
        return PCLXLStream(
            pjlHeader: pjlHeader, streamHeader: streamHeader, operators: operators, pjlTrailer: pjlTrailer)
    }
}

/// Element widths and signedness shared by the scalar, array, xy and box tags.
private enum ElementKind {
    case ubyte, uint16, uint32, sint16, sint32, real32

    var width: Int {
        switch self {
        case .ubyte: 1
        case .uint16, .sint16: 2
        case .uint32, .sint32, .real32: 4
        }
    }

    var isReal: Bool { self == .real32 }
}

private enum ElementShape {
    case scalar, array, xy, box
}

extension PCLXLDataTag {
    fileprivate var elementKind: ElementKind {
        switch self {
        case .ubyte, .ubyteArray, .ubyteXY, .ubyteBox: .ubyte
        case .uint16, .uint16Array, .uint16XY, .uint16Box: .uint16
        case .uint32, .uint32Array, .uint32XY, .uint32Box: .uint32
        case .sint16, .sint16Array, .sint16XY, .sint16Box: .sint16
        case .sint32, .sint32Array, .sint32XY, .sint32Box: .sint32
        case .real32, .real32Array, .real32XY, .real32Box: .real32
        }
    }

    fileprivate var elementShape: ElementShape {
        switch self {
        case .ubyte, .uint16, .uint32, .sint16, .sint32, .real32: .scalar
        case .ubyteArray, .uint16Array, .uint32Array, .sint16Array, .sint32Array, .real32Array: .array
        case .ubyteXY, .uint16XY, .uint32XY, .sint16XY, .sint32XY, .real32XY: .xy
        case .ubyteBox, .uint16Box, .uint32Box, .sint16Box, .sint32Box, .real32Box: .box
        }
    }
}

/// Little-endian byte reader over the whole job.
private struct Scanner {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }

    var remaining: Int { max(0, bytes.count - offset) }

    func peek(_ ahead: Int = 0) -> UInt8? {
        let index = offset + ahead
        return index < bytes.count ? bytes[index] : nil
    }

    func matches(_ pattern: [UInt8]) -> Bool {
        guard offset + pattern.count <= bytes.count else { return false }
        for (index, byte) in pattern.enumerated() where bytes[offset + index] != byte { return false }
        return true
    }

    func matchesASCII(_ text: String) -> Bool {
        matches(Array(text.utf8))
    }

    mutating func advance(by count: Int) {
        offset = min(offset + count, bytes.count)
    }

    mutating func takeByte() throws -> UInt8 {
        guard offset < bytes.count else { throw PCLXLError.truncated(offset: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func takeBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw PCLXLError.truncated(offset: offset) }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skipWhiteSpace() {
        while let byte = peek(), byte == 0x00 || byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
            offset += 1
        }
    }

    /// Reads to the next LF (required unless `allowEOF`), dropping a trailing CR.
    mutating func readLine(allowEOF: Bool = false) throws -> String {
        let start = offset
        while offset < bytes.count, bytes[offset] != 0x0A {
            offset += 1
        }
        var end = offset
        if offset < bytes.count {
            offset += 1
        } else if !allowEOF {
            throw PCLXLError.truncated(offset: end)
        }
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    mutating func readPJLBlock() throws -> [String] {
        guard matches(PCLXLReader.uel) else { return [] }
        advance(by: PCLXLReader.uel.count)
        var lines: [String] = []
        while matchesASCII("@PJL") {
            lines.append(try readLine())
        }
        return lines
    }

    mutating func readStreamHeaderLine() throws -> String {
        skipWhiteSpace()
        guard let binding = peek() else { throw PCLXLError.truncated(offset: offset) }
        switch binding {
        case 0x29:
            return try readLine()
        case 0x28:
            throw PCLXLError.unsupported("big-endian binary binding '(' at offset \(offset)")
        case 0x27:
            throw PCLXLError.unsupported("ASCII binding '\'' at offset \(offset)")
        default:
            throw PCLXLError.unexpectedTag(binding, offset: offset)
        }
    }

    mutating func readTrailingPJL() throws -> [String] {
        var lines: [String] = []
        while !isAtEnd {
            skipWhiteSpace()
            if isAtEnd { break }
            if matches(PCLXLReader.uel) {
                advance(by: PCLXLReader.uel.count)
                continue
            }
            guard matchesASCII("@PJL") else { break }
            lines.append(try readLine(allowEOF: true))
        }
        return lines
    }

    mutating func readAttributeID() throws -> UInt8 {
        let tagOffset = offset
        let tag = try takeByte()
        switch tag {
        case PCLXLStructureTag.attributeUByte:
            return try takeByte()
        case PCLXLStructureTag.attributeUInt16:
            let low = try takeByte()
            let high = try takeByte()
            let id = UInt16(low) | UInt16(high) << 8
            guard id <= 0xFF else { throw PCLXLError.unsupported("attribute id \(id) above 255") }
            return UInt8(id)
        default:
            throw PCLXLError.unexpectedTag(tag, offset: tagOffset)
        }
    }

    /// Reads the `0xFA` / `0xFB` embedded-data block that may follow an operator.
    mutating func readEmbeddedData() throws -> [UInt8]? {
        skipWhiteSpace()
        switch peek() {
        case PCLXLStructureTag.dataLength:
            advance(by: 1)
            let raw = try takeBytes(4)
            let length = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
            guard let count = Int(exactly: length) else { throw PCLXLError.truncated(offset: offset) }
            return try takeBytes(count)
        case PCLXLStructureTag.dataLengthByte:
            advance(by: 1)
            return try takeBytes(Int(try takeByte()))
        default:
            return nil
        }
    }

    mutating func readValue() throws -> (tag: PCLXLDataTag, value: PCLXLValue) {
        let tagOffset = offset
        let raw = try takeByte()
        guard let tag = PCLXLDataTag(rawValue: raw) else {
            throw PCLXLError.unexpectedTag(raw, offset: tagOffset)
        }
        let kind = tag.elementKind
        switch tag.elementShape {
        case .scalar:
            return (tag, kind.isReal ? .real(try readFloat()) : .integer(try readInt(kind)))
        case .xy:
            return (tag, try readSequence(kind, count: 2, asBytes: false))
        case .box:
            return (tag, try readSequence(kind, count: 4, asBytes: false))
        case .array:
            let count = try readArrayLength()
            return (tag, try readSequence(kind, count: count, asBytes: kind == .ubyte))
        }
    }

    /// An array length is itself a tagged scalar: `0xC0` + one byte, or `0xC1` + two bytes.
    private mutating func readArrayLength() throws -> Int {
        let tagOffset = offset
        let tag = try takeByte()
        switch tag {
        case PCLXLDataTag.ubyte.rawValue:
            return Int(try takeByte())
        case PCLXLDataTag.uint16.rawValue:
            return try readInt(.uint16)
        default:
            throw PCLXLError.unexpectedTag(tag, offset: tagOffset)
        }
    }

    private mutating func readSequence(_ kind: ElementKind, count: Int, asBytes: Bool) throws -> PCLXLValue {
        if asBytes {
            return .bytes(try takeBytes(count))
        }
        if kind.isReal {
            var values: [Float] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try readFloat()) }
            return .reals(values)
        }
        var values: [Int] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try readInt(kind)) }
        return .integers(values)
    }

    private mutating func readInt(_ kind: ElementKind) throws -> Int {
        let raw = try takeBytes(kind.width)
        var value: UInt32 = 0
        for (index, byte) in raw.enumerated() { value |= UInt32(byte) << (8 * index) }
        switch kind {
        case .ubyte, .uint16, .uint32: return Int(value)
        case .sint16: return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
        case .sint32: return Int(Int32(bitPattern: value))
        case .real32: return Int(value)
        }
    }

    private mutating func readFloat() throws -> Float {
        let raw = try takeBytes(4)
        var value: UInt32 = 0
        for (index, byte) in raw.enumerated() { value |= UInt32(byte) << (8 * index) }
        return Float(bitPattern: value)
    }
}
