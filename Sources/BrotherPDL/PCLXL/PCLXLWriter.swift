/// Builds the little-endian binary PCL XL binding into a byte buffer.
///
/// An attribute is a tagged value followed by the attribute id; an operator consumes the
/// attributes written since the previous operator.
public struct PCLXLWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Removes and returns everything written so far, keeping the allocation for reuse.
    public mutating func take() -> [UInt8] {
        defer { bytes.removeAll(keepingCapacity: true) }
        return bytes
    }

    /// `) HP-PCL XL;<major>;<minor>;<comment>\n`
    public mutating func streamHeader(protocolClass: (major: Int, minor: Int), comment: String) {
        bytes.append(contentsOf: ") HP-PCL XL;\(protocolClass.major);\(protocolClass.minor);\(comment)\n".utf8)
    }

    public mutating func op(_ op: PCLXLOperator) {
        bytes.append(op.rawValue)
    }

    public mutating func ubyte(_ value: UInt8, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.ubyte.rawValue)
        bytes.append(value)
        attr(attribute)
    }

    public mutating func enumeration<E: RawRepresentable>(_ value: E, _ attribute: PCLXLAttribute) where E.RawValue == UInt8 {
        ubyte(value.rawValue, attribute)
    }

    public mutating func uint16(_ value: Int, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.uint16.rawValue)
        le16(value)
        attr(attribute)
    }

    public mutating func uint32(_ value: Int, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.uint32.rawValue)
        le32(value)
        attr(attribute)
    }

    public mutating func uint16XY(_ x: Int, _ y: Int, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.uint16XY.rawValue)
        le16(x)
        le16(y)
        attr(attribute)
    }

    /// A real32 xy pair. This driver writes device pixels, which are whole numbers, so nothing in
    /// it emits one — but the readers and the validator accept the shape, and a test that checks
    /// they do needs a way to produce it.
    public mutating func real32XY(_ x: Float, _ y: Float, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.real32XY.rawValue)
        le32(Int(x.bitPattern))
        le32(Int(y.bitPattern))
        attr(attribute)
    }

    public mutating func uint32XY(_ x: Int, _ y: Int, _ attribute: PCLXLAttribute) {
        bytes.append(PCLXLDataTag.uint32XY.rawValue)
        le32(x)
        le32(y)
        attr(attribute)
    }

    /// Introduces `length` bytes of embedded data. The caller writes the data itself.
    public mutating func dataLength(_ length: Int) {
        if length < 256 {
            bytes.append(PCLXLStructureTag.dataLengthByte)
            bytes.append(UInt8(length))
        } else {
            bytes.append(PCLXLStructureTag.dataLength)
            le32(length)
        }
    }

    private mutating func attr(_ attribute: PCLXLAttribute) {
        bytes.append(PCLXLStructureTag.attributeUByte)
        bytes.append(attribute.rawValue)
    }

    private mutating func le16(_ value: Int) {
        let v = UInt16(clamping: value)
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private mutating func le32(_ value: Int) {
        let v = UInt32(clamping: value)
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }
}
