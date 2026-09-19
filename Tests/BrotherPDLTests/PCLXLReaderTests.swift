import Testing

@testable import BrotherPDL

/// A PCL XL job assembled byte by byte from the format description, independent of any writer.
struct HandBuiltJob {
    static let uel: [UInt8] = [0x1B, 0x25, 0x2D, 0x31, 0x32, 0x33, 0x34, 0x35, 0x58]
    static let defaultHeader = ") HP-PCL XL;2;0;Hand built"

    private(set) var bytes: [UInt8] = []

    var offset: Int { bytes.count }

    mutating func raw(_ values: [UInt8]) { bytes += values }

    mutating func ascii(_ text: String) { bytes += Array(text.utf8) }

    mutating func pjl(_ lines: [String], crlf: Bool = false) {
        bytes += Self.uel
        for line in lines {
            ascii(line)
            raw(crlf ? [0x0D, 0x0A] : [0x0A])
        }
    }

    mutating func header(_ text: String = defaultHeader, crlf: Bool = false) {
        ascii(text)
        raw(crlf ? [0x0D, 0x0A] : [0x0A])
    }

    mutating func trailer(_ lines: [String]) {
        bytes += Self.uel
        for line in lines {
            ascii(line)
            raw([0x0A])
        }
    }

    mutating func endOfJob() { bytes += Self.uel }

    // Values.

    mutating func ubyte(_ value: UInt8) { raw([0xC0, value]) }
    mutating func uint16(_ value: UInt16) { raw([0xC1] + Self.le16(value)) }
    mutating func uint32(_ value: UInt32) { raw([0xC2] + Self.le32(value)) }
    mutating func sint16(_ value: Int16) { raw([0xC3] + Self.le16(UInt16(bitPattern: value))) }
    mutating func sint32(_ value: Int32) { raw([0xC4] + Self.le32(UInt32(bitPattern: value))) }
    mutating func real32(_ value: Float) { raw([0xC5] + Self.le32(value.bitPattern)) }

    mutating func ubyteArray(_ values: [UInt8], longLength: Bool = false) {
        raw([0xC8] + Self.length(values.count, long: longLength) + values)
    }

    mutating func uint16Array(_ values: [UInt16], longLength: Bool = false) {
        raw([0xC9] + Self.length(values.count, long: longLength) + values.flatMap(Self.le16))
    }

    mutating func uint16XY(_ x: UInt16, _ y: UInt16) { raw([0xD1] + Self.le16(x) + Self.le16(y)) }

    mutating func sint16XY(_ x: Int16, _ y: Int16) {
        raw([0xD3] + Self.le16(UInt16(bitPattern: x)) + Self.le16(UInt16(bitPattern: y)))
    }

    mutating func uint16Box(_ values: [UInt16]) { raw([0xE1] + values.flatMap(Self.le16)) }

    // Attributes, operators and embedded data.

    mutating func attr(_ attribute: PCLXLAttribute) { raw([0xF8, attribute.rawValue]) }
    mutating func attr(id: UInt8) { raw([0xF8, id]) }
    mutating func attr(wideID: UInt16) { raw([0xF9] + Self.le16(wideID)) }
    mutating func op(_ code: PCLXLOperator) { raw([code.rawValue]) }
    mutating func op(raw code: UInt8) { raw([code]) }
    mutating func data(_ payload: [UInt8]) { raw([0xFA] + Self.le32(UInt32(payload.count)) + payload) }
    mutating func shortData(_ payload: [UInt8]) { raw([0xFB, UInt8(payload.count)] + payload) }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    private static func length(_ count: Int, long: Bool) -> [UInt8] {
        long ? [0xC1] + le16(UInt16(count)) : [0xC0, UInt8(count)]
    }
}

/// Error-shape checks for the hand-built reader and renderer suites.
enum PCLXLCheck {
    /// Runs `body` and returns the `PCLXLError` it threw, or nil.
    static func error(_ body: () throws -> Void) -> PCLXLError? {
        do {
            try body()
            return nil
        } catch let error as PCLXLError {
            return error
        } catch {
            return nil
        }
    }

    static func isMalformed(_ error: PCLXLError?) -> Bool {
        if case .malformed = error { true } else { false }
    }

    static func isUnsupported(_ error: PCLXLError?) -> Bool {
        if case .unsupported = error { true } else { false }
    }
}

@Suite struct PCLXLReaderTests {
    @Test func parsesEveryScalarType() throws {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(42)
        job.attr(id: 1)
        job.uint16(0xBEEF)
        job.attr(id: 2)
        job.uint32(0xDEAD_BEEF)
        job.attr(id: 3)
        job.sint16(-2)
        job.attr(id: 4)
        job.sint32(-70_000)
        job.attr(id: 5)
        job.real32(1.5)
        job.attr(id: 6)
        job.op(.comment)

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.streamHeader == HandBuiltJob.defaultHeader)
        #expect(stream.pjlHeader.isEmpty)
        #expect(stream.operators.count == 1)
        #expect(
            stream.operators[0].attributes.map(\.value) == [
                .integer(42), .integer(48879), .integer(3_735_928_559),
                .integer(-2), .integer(-70_000), .real(1.5),
            ])
        #expect(stream.operators[0].attributes.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test func parsesArraysWithBothLengthEncodings() throws {
        var job = HandBuiltJob()
        job.header()
        job.ubyteArray([1, 2, 3])
        job.attr(.commentData)
        job.ubyteArray([9, 8], longLength: true)
        job.attr(id: 20)
        job.uint16Array([1000, 2000, 3000])
        job.attr(id: 21)
        job.uint16Array([7], longLength: true)
        job.attr(id: 22)
        job.op(.comment)

        let record = try PCLXLReader.parse(job.bytes).operators[0]
        #expect(record[.commentData] == .bytes([1, 2, 3]))
        #expect(record.attributes[1].value == .bytes([9, 8]))
        #expect(record.attributes[2].value == .integers([1000, 2000, 3000]))
        #expect(record.attributes[3].value == .integers([7]))
    }

    @Test func parsesXYAndBox() throws {
        var job = HandBuiltJob()
        job.header()
        job.uint16XY(600, 600)
        job.attr(.unitsPerMeasure)
        job.sint16XY(-5, 7)
        job.attr(.point)
        job.uint16Box([1, 2, 3, 4])
        job.attr(.customMediaSize)
        job.op(.beginSession)

        let record = try PCLXLReader.parse(job.bytes).operators[0]
        #expect(record[.unitsPerMeasure]?.intArray == [600, 600])
        #expect(record[.point]?.intArray == [-5, 7])
        #expect(record[.customMediaSize]?.intArray == [1, 2, 3, 4])
    }

    @Test func attachesEmbeddedDataWithBothLengthTags() throws {
        var job = HandBuiltJob()
        job.header()
        job.op(.readImage)
        job.data([0xAA, 0xBB, 0xCC])
        job.op(.readImage)
        job.shortData([0x01])
        job.op(.endImage)

        let operators = try PCLXLReader.parse(job.bytes).operators
        #expect(operators.count == 3)
        #expect(operators[0].data == [0xAA, 0xBB, 0xCC])
        #expect(operators[1].data == [0x01])
        #expect(operators[2].data == nil)
    }

    @Test func skipsWhiteSpaceBetweenElements() throws {
        var job = HandBuiltJob()
        job.header()
        job.raw([0x00, 0x09, 0x0A, 0x0D, 0x20])
        job.ubyte(3)
        job.raw([0x20, 0x0A])
        job.attr(.colorSpace)
        job.raw([0x20])
        job.op(.setColorSpace)
        job.raw([0x0A, 0x20])
        job.shortData([0x7F])
        job.raw([0x20])
        job.op(.endSession)

        let operators = try PCLXLReader.parse(job.bytes).operators
        #expect(operators.count == 2)
        #expect(operators[0][.colorSpace] == .integer(3))
        #expect(operators[0].data == [0x7F])
    }

    @Test func readsTwoByteAttributeIDs() throws {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(1)
        job.attr(wideID: 3)
        job.op(.setColorSpace)

        let record = try PCLXLReader.parse(job.bytes).operators[0]
        #expect(record[.colorSpace] == .integer(1))
    }

    @Test func rejectsAttributeIDsAboveAByte() {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(1)
        job.attr(wideID: 300)
        job.op(.setColorSpace)

        #expect(PCLXLCheck.isUnsupported(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) }))
    }

    @Test func parsesPJLWrapperWithLFLineEndings() throws {
        var job = HandBuiltJob()
        job.pjl(["@PJL SET RESOLUTION=600", "@PJL ENTER LANGUAGE=PCLXL"])
        job.header()
        job.op(.beginSession)

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.pjlHeader == ["@PJL SET RESOLUTION=600", "@PJL ENTER LANGUAGE=PCLXL"])
        #expect(stream.operators.count == 1)
    }

    @Test func parsesPJLWrapperWithCRLFLineEndings() throws {
        var job = HandBuiltJob()
        job.pjl(["@PJL JOB NAME=\"x\"", "@PJL ENTER LANGUAGE = PCLXL"], crlf: true)
        job.header(crlf: true)
        job.op(.beginSession)

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.pjlHeader == ["@PJL JOB NAME=\"x\"", "@PJL ENTER LANGUAGE = PCLXL"])
        #expect(stream.streamHeader == HandBuiltJob.defaultHeader)
    }

    @Test func parsesStreamWithoutAnyPJL() throws {
        var job = HandBuiltJob()
        job.header()
        job.op(.beginSession)
        job.op(.endSession)

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.pjlHeader.isEmpty)
        #expect(stream.pjlTrailer.isEmpty)
        #expect(stream.operators.map(\.tag) == [0x41, 0x42])
    }

    @Test func readsTrailingPJLAfterTheClosingUEL() throws {
        var job = HandBuiltJob()
        job.pjl(["@PJL ENTER LANGUAGE=PCLXL"])
        job.header()
        job.op(.endSession)
        job.trailer(["@PJL EOJ", "@PJL RESET"])
        job.endOfJob()

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.operators.map(\.tag) == [0x42])
        #expect(stream.pjlTrailer == ["@PJL EOJ", "@PJL RESET"])
    }

    @Test func embeddedDataMayContainTheUELBytes() throws {
        var job = HandBuiltJob()
        job.header()
        job.op(.readImage)
        job.data(HandBuiltJob.uel + [0x00, 0x01])
        job.op(.endImage)
        job.trailer(["@PJL EOJ"])

        let stream = try PCLXLReader.parse(job.bytes)
        #expect(stream.operators.count == 2)
        #expect(stream.operators[0].data == HandBuiltJob.uel + [0x00, 0x01])
        #expect(stream.pjlTrailer == ["@PJL EOJ"])
    }

    @Test func rejectsNonLittleEndianBindings() {
        for binding in [") ", "( ", "' "] {
            var job = HandBuiltJob()
            job.header(binding + "HP-PCL XL;2;0;")
            job.op(.endSession)
            let error = PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) }
            #expect(binding.hasPrefix(")") ? error == nil : PCLXLCheck.isUnsupported(error))
        }
    }

    @Test func rejectsAnUnknownBindingByte() {
        var job = HandBuiltJob()
        job.header("* HP-PCL XL;2;0;")
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .unexpectedTag(0x2A, offset: 0))
    }

    @Test func reportsTruncationInsideAScalar() {
        var job = HandBuiltJob()
        job.header()
        job.raw([0xC2, 0x01, 0x02])
        let offset = job.offset
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .truncated(offset: offset - 2))
    }

    @Test func reportsTruncationAfterAnAttributeTag() {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(1)
        job.raw([0xF8])
        let offset = job.offset
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .truncated(offset: offset))
    }

    @Test func reportsTruncationInsideEmbeddedData() {
        var job = HandBuiltJob()
        job.header()
        job.op(.readImage)
        job.raw([0xFA] + HandBuiltJob.le32(16) + [0x01, 0x02])
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .truncated(offset: job.offset - 2))
    }

    @Test func reportsTruncationInsideAnArray() {
        var job = HandBuiltJob()
        job.header()
        job.raw([0xC8, 0xC0, 0x04, 0x01, 0x02])
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .truncated(offset: job.offset - 2))
    }

    @Test func reportsTruncationOfTheStreamHeaderLine() {
        var job = HandBuiltJob()
        job.ascii(") HP-PCL XL;2;0;no newline")
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .truncated(offset: job.offset))
    }

    @Test func reportsAnUnexpectedTagWhereAValueOrOperatorIsExpected() {
        var job = HandBuiltJob()
        job.header()
        let offset = job.offset
        job.raw([0x30])
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .unexpectedTag(0x30, offset: offset))
    }

    @Test func reportsAnUnexpectedTagForAnInvalidDataType() {
        var job = HandBuiltJob()
        job.header()
        let offset = job.offset
        job.raw([0xC6, 0x00])
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .unexpectedTag(0xC6, offset: offset))
    }

    @Test func reportsAnUnexpectedTagWhenAValueIsNotFollowedByAnAttribute() {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(1)
        let offset = job.offset
        job.raw([0xC0, 0x02])
        job.op(.comment)
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .unexpectedTag(0xC0, offset: offset))
    }

    @Test func reportsAnUnexpectedTagForALoneEscape() {
        var job = HandBuiltJob()
        job.header()
        let offset = job.offset
        job.raw([0x1B, 0x40])
        #expect(PCLXLCheck.error { _ = try PCLXLReader.parse(job.bytes) } == .unexpectedTag(0x1B, offset: offset))
    }

    @Test func attributeSubscriptFindsValuesByName() throws {
        var job = HandBuiltJob()
        job.header()
        job.ubyte(2)
        job.attr(.colorDepth)
        job.uint16(1024)
        job.attr(.sourceWidth)
        job.op(.beginImage)

        let record = try PCLXLReader.parse(job.bytes).operators[0]
        #expect(record[.colorDepth]?.intValue == 2)
        #expect(record[.sourceWidth]?.intValue == 1024)
        #expect(record[.sourceHeight] == nil)
        #expect(record.offset == job.offset - 1)
    }

    @Test func recordsOperatorOffsets() throws {
        var job = HandBuiltJob()
        job.header()
        let first = job.offset
        job.op(.beginSession)
        job.ubyte(0)
        job.attr(.measure)
        let second = job.offset
        job.op(.beginPage)

        let operators = try PCLXLReader.parse(job.bytes).operators
        #expect(operators.map(\.offset) == [first, second])
        #expect(operators[0].attributes.isEmpty)
        #expect(operators[1][.measure] == .integer(0))
    }
}
