/// Checks a finished PCL XL job against the rules a printer enforces, without a printer.
///
/// The reader and the renderer answer "can this be decoded back to the right pixels". They are
/// forgiving about everything a decoder does not need: a missing attribute it can default, an
/// operator in an order it does not mind, a value the firmware would reject. A real PCL XL
/// interpreter is not forgiving — it answers with `PCL XL error … Operator: … Position: …` on the
/// back channel and prints nothing, which is exactly the failure a hardware session exists to find.
///
/// So this walks the stream the way an interpreter would: session, page and image nesting, the
/// attribute list of every operator (present, allowed, right data type, value in range), the
/// protocol class the stream declares against the features it uses, the row accounting of every
/// image, and where the images land on the sheet. It collects every finding instead of stopping at
/// the first, because a job is usually inspected once, by hand, a long way from the printer.
///
/// Errors are violations a printer is entitled to reject. Warnings are legal streams that this
/// driver should not be producing — a regression worth seeing before it reaches paper.
public enum PCLXLValidator {
    /// Validates a complete job, PJL wrapper included.
    public static func check(job bytes: [UInt8]) -> [PDLFinding] {
        // Framing is checked first and kept even when the parse fails: a job that was cut short
        // fails both, and "it does not end with a UEL" is the more useful half of that answer.
        var findings = framing(bytes)
        let stream: PCLXLStream
        do {
            stream = try PCLXLReader.parse(bytes)
        } catch {
            let offset = (error as? PCLXLError).flatMap(Self.offset(of:))
            findings.append(.error("parse", "the job does not parse as PCL XL: \(error)", at: offset))
            return findings
        }
        findings += check(stream)
        return findings.sorted { ($0.offset ?? 0, $0.rule) < ($1.offset ?? 0, $1.rule) }
    }

    /// Validates a parsed stream. `check(job:)` also checks the raw framing around it.
    public static func check(_ stream: PCLXLStream) -> [PDLFinding] {
        var findings = pjl(stream)
        let protocolClass = self.protocolClass(stream.streamHeader, into: &findings)
        var walk = Walk(protocolClass: protocolClass)
        for record in stream.operators {
            walk.visit(record, into: &findings)
        }
        walk.finish(into: &findings)
        return findings
    }

    // MARK: - Raw framing

    /// The bytes around the stream: a job must arrive in PJL and leave the printer back in PJL.
    private static func framing(_ bytes: [UInt8]) -> [PDLFinding] {
        var findings: [PDLFinding] = []
        if !bytes.starts(with: PCLXLReader.uel) {
            findings.append(
                .warning(
                    "framing", "the job does not open with a UEL, so it prints only if the printer is already in PCL XL",
                    at: 0))
        }
        // Trailing whitespace is harmless; anything else means the printer is left inside the job.
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D || bytes[end - 1] == 0x20 {
            end -= 1
        }
        if end < PCLXLReader.uel.count || !Array(bytes[(end - PCLXLReader.uel.count)..<end]).elementsEqual(PCLXLReader.uel) {
            findings.append(
                .error("framing", "the job does not end with a UEL: the printer is left inside the job", at: max(0, end - 1)))
        }
        return findings
    }

    // MARK: - PJL wrapper

    private static func pjl(_ stream: PCLXLStream) -> [PDLFinding] {
        var findings: [PDLFinding] = []
        guard !stream.pjlHeader.isEmpty else { return findings }

        for line in stream.pjlHeader {
            if !line.hasPrefix("@PJL") {
                findings.append(.error("pjl-line", "PJL line does not start with @PJL: \(quoted(line))"))
            }
            if line.contains(where: { !$0.isASCII || $0.asciiValue.map { $0 < 0x20 } == true }) {
                findings.append(.error("pjl-line", "PJL line is not printable ASCII: \(quoted(line))"))
            }
            // PJL's own limit: 80 characters per line including the @PJL prefix and the terminator.
            if line.count > 80 {
                findings.append(.warning("pjl-line", "PJL line is \(line.count) characters, over PJL's 80: \(quoted(line))"))
            }
        }
        if let last = stream.pjlHeader.last {
            // Brother's own drivers write this line without spaces; other vendors' PJL has them.
            let normalized = String(last.filter { $0 != " " })
            if normalized != "@PJLENTERLANGUAGE=PCLXL" {
                findings.append(
                    .error(
                        "pjl-enter-language",
                        "the last PJL line before the stream is \(quoted(last)), not @PJL ENTER LANGUAGE=PCLXL"))
            }
        }
        return findings
    }

    /// Reads `) HP-PCL XL;<major>;<minor>;<comment>`; defaults to 2.0 when it cannot be read.
    private static func protocolClass(_ header: String, into findings: inout [PDLFinding]) -> (major: Int, minor: Int) {
        let fields = header.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[0] == ") HP-PCL XL", let major = Int(fields[1]), let minor = Int(fields[2]) else {
            findings.append(.error("stream-header", "unreadable stream header \(quoted(header))"))
            return (2, 0)
        }
        if major != 2 || minor > 1 {
            findings.append(
                .warning("stream-header", "protocol class \(major).\(minor) is not one this driver has support for"))
        }
        return (major, minor)
    }

    private static func quoted(_ text: String) -> String { "\"\(text)\"" }

    private static func offset(of error: PCLXLError) -> Int? {
        switch error {
        case .truncated(let offset): offset
        case .unexpectedTag(_, let offset): offset
        case .malformed, .unsupported: nil
        }
    }
}

// MARK: - The walk

/// Interpreter-shaped state: what is open, what has been set, and how far through an image we are.
private struct Walk {
    let protocolClass: (major: Int, minor: Int)

    private var sessionOpen = false
    private var sessionEnded = false
    private var dataSourceOpen = false
    private var sawDataSource = false
    private var pageOpen = false
    private var pages = 0
    private var image: Image?
    private var images = 0

    /// Session units, from BeginSession: how many user units make one `measure`.
    private var unitsPerMeasure = (x: 0, y: 0)
    /// The sheet in user units, when BeginPage said which sheet it is.
    private var sheet: (width: Int, height: Int)?
    private var cursor: (x: Int, y: Int)?
    private var colorSpace: PCLXLColorSpace?

    /// What the open image declared, and how much of it has arrived.
    private struct Image {
        var width: Int
        var height: Int
        var bytesPerPixel: Int
        var rowsRead = 0
    }

    init(protocolClass: (major: Int, minor: Int)) {
        self.protocolClass = protocolClass
    }

    mutating func visit(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard let op = PCLXLOperator(rawValue: record.tag) else {
            findings.append(
                .error(
                    "operator", "operator 0x\(String(record.tag, radix: 16)) is not one this driver emits",
                    at: record.offset))
            return
        }
        OperatorSpec.all[op]?.check(record, named: String(describing: op), into: &findings)
        if op != .readImage, record.data != nil {
            findings.append(
                .error("operator-data", "\(op) carries embedded data, which only ReadImage may", at: record.offset))
        }
        sequence(op, record, into: &findings)
    }

    mutating func finish(into findings: inout [PDLFinding]) {
        if !sessionOpen && !sessionEnded {
            findings.append(.error("session", "the stream contains no BeginSession"))
        }
        if sessionOpen {
            findings.append(.error("session", "the stream ends without an EndSession"))
        }
        if pageOpen {
            findings.append(.error("page", "the stream ends inside a page"))
        }
        if image != nil {
            findings.append(.error("image", "the stream ends inside an image"))
        }
        if sessionEnded && pages == 0 {
            findings.append(.warning("page", "the job contains no pages"))
        }
    }

    // MARK: Operator sequence

    private mutating func sequence(
        _ op: PCLXLOperator, _ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]
    ) {
        func require(_ condition: Bool, _ rule: String, _ message: String) {
            if !condition { findings.append(.error(rule, message, at: record.offset)) }
        }

        if sessionEnded {
            require(false, "session", "\(op) comes after EndSession")
            return
        }
        if op != .beginSession {
            require(sessionOpen, "session", "\(op) outside a session")
        }

        switch op {
        case .beginSession:
            require(!sessionOpen, "session", "BeginSession inside a session")
            sessionOpen = true
            unitsPerMeasure = xy(record, .unitsPerMeasure) ?? (0, 0)
            if unitsPerMeasure.x != unitsPerMeasure.y {
                findings.append(
                    .warning(
                        "units-per-measure",
                        "UnitsPerMeasure is \(unitsPerMeasure.x)×\(unitsPerMeasure.y); this driver sends square units",
                        at: record.offset))
            }

        case .endSession:
            require(!pageOpen, "page", "EndSession inside a page")
            require(sawDataSource, "data-source", "the session has no OpenDataSource")
            require(!dataSourceOpen, "data-source", "EndSession with the data source still open")
            sessionOpen = false
            sessionEnded = true

        case .openDataSource:
            require(!dataSourceOpen, "data-source", "OpenDataSource with a data source already open")
            require(pages == 0 && !pageOpen, "data-source", "OpenDataSource after the first page has started")
            dataSourceOpen = true
            sawDataSource = true

        case .closeDataSource:
            require(dataSourceOpen, "data-source", "CloseDataSource without an open data source")
            require(!pageOpen, "page", "CloseDataSource inside a page")
            dataSourceOpen = false

        case .beginPage:
            require(!pageOpen, "page", "BeginPage inside a page")
            require(dataSourceOpen, "data-source", "BeginPage with no open data source")
            pageOpen = true
            pages += 1
            images = 0
            // A page starts with a fresh graphics state: the cursor and colour space do not carry over.
            cursor = nil
            colorSpace = nil
            sheet = sheetSize(record, into: &findings)
            duplexAttributes(record, into: &findings)

        case .endPage:
            require(pageOpen, "page", "EndPage without BeginPage")
            require(image == nil, "image", "EndPage inside an image")
            if images == 0 {
                findings.append(.warning("page", "page \(pages) carries no images", at: record.offset))
            }
            if let copies = record[.pageCopies]?.intValue, copies != 1 {
                findings.append(
                    .warning(
                        "page-copies", "PageCopies is \(copies); this driver sends each copy as its own page",
                        at: record.offset))
            }
            pageOpen = false

        case .setCursor:
            require(pageOpen, "page", "SetCursor outside a page")
            if let point = xy(record, .point) {
                cursor = point
            }

        case .setPageOrigin:
            require(pageOpen, "page", "SetPageOrigin outside a page")

        case .setColorSpace:
            require(pageOpen, "page", "SetColorSpace outside a page")
            colorSpace = (record[.colorSpace]?.intValue).flatMap { UInt8(exactly: $0) }.flatMap(PCLXLColorSpace.init)

        case .beginImage:
            require(pageOpen, "page", "BeginImage outside a page")
            require(image == nil, "image", "BeginImage inside an image")
            beginImage(record, into: &findings)
            images += 1

        case .readImage:
            readImage(record, into: &findings)

        case .endImage:
            endImage(record, into: &findings)

        case .comment, .pushGS, .popGS:
            break
        }
    }

    // MARK: Pages

    /// The sheet in user units, from MediaSize or CustomMediaSize, reporting what is missing.
    private mutating func sheetSize(
        _ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]
    ) -> (width: Int, height: Int)? {
        let standard = record[.mediaSize]?.intValue
        let custom = xy(record, .customMediaSize)
        switch (standard, custom) {
        case (nil, nil):
            findings.append(
                .error("media-size", "BeginPage names neither MediaSize nor CustomMediaSize", at: record.offset))
            return nil
        case (.some, .some):
            findings.append(
                .error("media-size", "BeginPage names both MediaSize and CustomMediaSize", at: record.offset))
            return nil
        case (.some(let code), nil):
            guard let size = UInt8(exactly: code).flatMap(PCLXLMediaSize.init),
                let media = MediaSize.all.first(where: { $0.pclxl == size })
            else {
                // A code this driver does not use: legal, but its dimensions are not known here.
                return nil
            }
            return (units(points: media.widthPoints, along: .x), units(points: media.heightPoints, along: .y))
        case (nil, .some(let size)):
            guard let units = record[.customMediaSizeUnits]?.intValue else {
                findings.append(
                    .error(
                        "custom-media-units", "CustomMediaSize without CustomMediaSizeUnits, so its unit is anyone's guess",
                        at: record.offset))
                return nil
            }
            guard let measure = UInt8(exactly: units).flatMap(PCLXLMeasure.init) else { return nil }
            let perInch: Double =
                switch measure {
                case .inch: 1
                case .millimeter: 25.4
                case .tenthsOfAMillimeter: 254
                }
            return (
                self.units(points: Double(size.x) * 72 / perInch, along: .x),
                self.units(points: Double(size.y) * 72 / perInch, along: .y)
            )
        }
    }

    private func units(points: Double, along axis: Axis) -> Int {
        let perMeasure = axis == .x ? unitsPerMeasure.x : unitsPerMeasure.y
        return Int((points * Double(perMeasure) / 72).rounded())
    }

    private enum Axis { case x, y }

    private func duplexAttributes(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        let simplex = record[.simplexPageMode] != nil
        let duplex = record[.duplexPageMode] != nil
        if simplex && duplex {
            findings.append(
                .error("duplex", "BeginPage sends both SimplexPageMode and DuplexPageMode", at: record.offset))
        }
        if record[.duplexPageSide] != nil && !duplex {
            findings.append(
                .error("duplex", "BeginPage sends DuplexPageSide without DuplexPageMode", at: record.offset))
        }
        if !simplex && !duplex {
            findings.append(
                .warning(
                    "duplex", "BeginPage sends neither SimplexPageMode nor DuplexPageMode, leaving the side to the printer",
                    at: record.offset))
        }
    }

    // MARK: Images

    private mutating func beginImage(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard let width = record[.sourceWidth]?.intValue, let height = record[.sourceHeight]?.intValue,
            let destination = xy(record, .destinationSize)
        else {
            return  // The attribute rules have already reported what is missing.
        }
        guard let cursor else {
            findings.append(
                .error(
                    "cursor", "BeginImage with no SetCursor on this page: the image lands wherever the cursor happens to be",
                    at: record.offset))
            return
        }
        if colorSpace == nil {
            findings.append(
                .error(
                    "color-space", "BeginImage with no SetColorSpace on this page: the page's colour space is undefined",
                    at: record.offset))
        }
        if destination.x != width || destination.y != height {
            findings.append(
                .warning(
                    "image-scale",
                    "image is \(width)×\(height) into \(destination.x)×\(destination.y) user units; this driver never scales",
                    at: record.offset))
        }
        if let sheet {
            let right = cursor.x + destination.x
            let bottom = cursor.y + destination.y
            if cursor.x < 0 || cursor.y < 0 || right > sheet.width || bottom > sheet.height {
                findings.append(
                    .error(
                        "image-off-sheet",
                        "image covers \(cursor.x),\(cursor.y)–\(right),\(bottom) of a \(sheet.width)×\(sheet.height) sheet",
                        at: record.offset))
            }
        }
        let depth = record[.colorDepth]?.intValue
        let bitsPerComponent = depth == Int(PCLXLColorDepth.bits8.rawValue) ? 8 : depth == Int(PCLXLColorDepth.bits4.rawValue) ? 4 : 1
        let components = colorSpace == .gray ? 1 : 3
        image = Image(width: width, height: height, bytesPerPixel: bitsPerComponent * components / 8)
    }

    private mutating func readImage(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard var state = image else {
            findings.append(.error("image", "ReadImage outside an image", at: record.offset))
            return
        }
        defer { image = state }

        if let mode = (record[.compressMode]?.intValue).flatMap({ UInt8(exactly: $0) }).flatMap(PCLXLCompressMode.init) {
            // DeltaRow and JPEG arrived with protocol class 2.1; a 2.0 stream may not use them.
            if (mode == .deltaRow || mode == .jpeg) && (protocolClass.major, protocolClass.minor) < (2, 1) {
                findings.append(
                    .error(
                        "compress-mode-class",
                        "CompressMode \(mode) needs protocol class 2.1; the stream header declares "
                            + "\(protocolClass.major).\(protocolClass.minor)",
                        at: record.offset))
            }
            if mode == .none, let data = record.data, state.bytesPerPixel > 0 {
                // Uncompressed rows are padded to a multiple of four bytes, so the block's size is exact.
                let bytesPerRow = state.width * state.bytesPerPixel
                let padded = bytesPerRow + (-bytesPerRow & 3)
                let blockHeight = record[.blockHeight]?.intValue ?? 0
                if data.count != padded * blockHeight {
                    findings.append(
                        .error(
                            "image-data-length",
                            "uncompressed block carries \(data.count) bytes, not the \(padded * blockHeight) "
                                + "that \(blockHeight) rows of \(state.width) pixels need",
                            at: record.offset))
                }
            }
        }
        if record.data == nil {
            findings.append(.error("image-data", "ReadImage carries no data block", at: record.offset))
        }

        guard let startLine = record[.startLine]?.intValue, let blockHeight = record[.blockHeight]?.intValue else {
            return
        }
        if startLine != state.rowsRead {
            findings.append(
                .error(
                    "image-start-line", "ReadImage starts at line \(startLine); \(state.rowsRead) rows have been sent",
                    at: record.offset))
        }
        if state.rowsRead + blockHeight > state.height {
            findings.append(
                .error(
                    "image-block-height",
                    "ReadImage would carry the image past its SourceHeight: \(state.rowsRead) + \(blockHeight) "
                        + "rows of \(state.height)",
                    at: record.offset))
        }
        state.rowsRead += blockHeight
    }

    private mutating func endImage(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard let state = image else {
            findings.append(.error("image", "EndImage without BeginImage", at: record.offset))
            return
        }
        if state.rowsRead != state.height {
            findings.append(
                .error(
                    "image-rows", "image declared \(state.height) rows and received \(state.rowsRead)",
                    at: record.offset))
        }
        image = nil
    }

    private func xy(_ record: PCLXLOperatorRecord, _ attribute: PCLXLAttribute) -> (x: Int, y: Int)? {
        guard let values = record[attribute]?.intArray, values.count == 2 else { return nil }
        return (values[0], values[1])
    }
}

// MARK: - Attribute rules

/// What one attribute may look like on one operator.
private struct AttributeSpec {
    var attribute: PCLXLAttribute
    var tags: Set<PCLXLDataTag>
    /// Legal values, for the scalar attributes whose range is fixed. Nil leaves the value unchecked.
    var values: ClosedRange<Int>?
    /// Values inside `values` that are nonetheless not defined, e.g. gaps in an enumeration.
    var excluding: Set<Int> = []
    var required: Bool

    static func required(
        _ attribute: PCLXLAttribute, _ tags: Set<PCLXLDataTag>, _ values: ClosedRange<Int>? = nil,
        excluding: Set<Int> = []
    ) -> Self {
        Self(attribute: attribute, tags: tags, values: values, excluding: excluding, required: true)
    }

    static func optional(
        _ attribute: PCLXLAttribute, _ tags: Set<PCLXLDataTag>, _ values: ClosedRange<Int>? = nil,
        excluding: Set<Int> = []
    ) -> Self {
        Self(attribute: attribute, tags: tags, values: values, excluding: excluding, required: false)
    }
}

/// Data-type groups, named once so the operator table stays readable.
private enum Tags {
    static let ubyte: Set<PCLXLDataTag> = [.ubyte]
    static let uint16: Set<PCLXLDataTag> = [.ubyte, .uint16]
    static let unsignedXY: Set<PCLXLDataTag> = [.ubyteXY, .uint16XY, .uint32XY, .real32XY]
    static let anyXY: Set<PCLXLDataTag> = unsignedXY.union([.sint16XY, .sint32XY])
    static let byteArray: Set<PCLXLDataTag> = [.ubyteArray]
}

/// The attribute list each operator this driver emits is allowed to carry.
///
/// Values follow HP's "PCL XL Feature Reference, Protocol Class 2.0/2.1", restricted to what a
/// raster driver needs. An attribute missing from an operator's entry is one the printer would
/// reject there, not merely one this driver does not send.
private struct OperatorSpec {
    var attributes: [AttributeSpec]

    static let all: [PCLXLOperator: OperatorSpec] = [
        .beginSession: OperatorSpec(attributes: [
            .required(.unitsPerMeasure, Tags.unsignedXY, 1...65535),
            .required(.measure, Tags.ubyte, 0...2),
            .optional(.errorReport, Tags.ubyte, 0...3),
        ]),
        .endSession: OperatorSpec(attributes: []),
        .openDataSource: OperatorSpec(attributes: [
            .required(.sourceType, Tags.ubyte, 0...0),
            .required(.dataOrg, Tags.ubyte, 0...1),
        ]),
        .closeDataSource: OperatorSpec(attributes: []),
        .beginPage: OperatorSpec(attributes: [
            .required(.orientation, Tags.ubyte, 0...3),
            // Code 13 ("eB5Paper") is a second spelling of JIS B5 that this driver never sends.
            .optional(.mediaSize, Tags.ubyte, 0...18, excluding: [13]),
            .optional(.customMediaSize, Tags.unsignedXY, 1...65535),
            .optional(.customMediaSizeUnits, Tags.ubyte, 0...2),
            .optional(.mediaSource, Tags.ubyte, 0...6),
            .optional(.mediaType, Tags.byteArray),
            .optional(.simplexPageMode, Tags.ubyte, 0...0),
            .optional(.duplexPageMode, Tags.ubyte, 0...1),
            .optional(.duplexPageSide, Tags.ubyte, 0...1),
        ]),
        .endPage: OperatorSpec(attributes: [
            .optional(.pageCopies, Tags.uint16, 1...32767)
        ]),
        .setColorSpace: OperatorSpec(attributes: [
            // 1 gray, 2 RGB, 6 sRGB; 3 (CMY), 4 (CIE) and 5 (CRGB) are not colour spaces this driver uses.
            .required(.colorSpace, Tags.ubyte, 1...6, excluding: [3, 4, 5]),
            .optional(.paletteDepth, Tags.ubyte, 0...2),
            .optional(.paletteData, Tags.byteArray),
        ]),
        .setCursor: OperatorSpec(attributes: [
            .required(.point, Tags.anyXY)
        ]),
        .setPageOrigin: OperatorSpec(attributes: [
            .required(.point, Tags.anyXY)
        ]),
        .beginImage: OperatorSpec(attributes: [
            .required(.colorMapping, Tags.ubyte, 0...1),
            .required(.colorDepth, Tags.ubyte, 0...2),
            .required(.sourceWidth, Tags.uint16, 1...65535),
            .required(.sourceHeight, Tags.uint16, 1...65535),
            .required(.destinationSize, Tags.unsignedXY, 1...65535),
        ]),
        .readImage: OperatorSpec(attributes: [
            .required(.startLine, Tags.uint16, 0...65535),
            .required(.blockHeight, Tags.uint16, 1...65535),
            .required(.compressMode, Tags.ubyte, 0...3),
            .optional(.padBytesMultiple, Tags.ubyte, 1...4),
            .optional(.blockByteLength, [.uint32]),
        ]),
        .endImage: OperatorSpec(attributes: []),
        .comment: OperatorSpec(attributes: [
            .optional(.commentData, Tags.byteArray)
        ]),
        .pushGS: OperatorSpec(attributes: []),
        .popGS: OperatorSpec(attributes: []),
    ]

    /// Every attribute on the operator is one it may carry, in a shape and range it accepts, once.
    func check(_ record: PCLXLOperatorRecord, named name: String, into findings: inout [PDLFinding]) {
        var seen: Set<UInt8> = []

        for attribute in record.attributes {
            guard seen.insert(attribute.id).inserted else {
                findings.append(
                    .error("attribute-duplicate", "\(name) sends \(label(attribute)) twice", at: attribute.offset))
                continue
            }
            guard let spec = attributes.first(where: { $0.attribute.rawValue == attribute.id }) else {
                findings.append(
                    .error("attribute-unknown", "\(name) does not take \(label(attribute))", at: attribute.offset))
                continue
            }
            guard spec.tags.contains(attribute.tag) else {
                findings.append(
                    .error(
                        "attribute-type",
                        "\(label(attribute)) is sent as \(attribute.tag), which \(name) does not accept",
                        at: attribute.offset))
                continue
            }
            guard let range = spec.values else { continue }
            for value in numbers(of: attribute.value) where !range.contains(value) || spec.excluding.contains(value) {
                findings.append(
                    .error(
                        "attribute-value", "\(label(attribute)) is \(value), outside \(range.lowerBound)…\(range.upperBound)",
                        at: attribute.offset))
                break
            }
        }

        for spec in attributes where spec.required && !seen.contains(spec.attribute.rawValue) {
            findings.append(
                .error("attribute-missing", "\(name) is missing \(spec.attribute)", at: record.offset))
        }
    }

    private func label(_ attribute: PCLXLAttributeRecord) -> String {
        attribute.attribute.map { String(describing: $0) } ?? "attribute \(attribute.id)"
    }

    private func numbers(of value: PCLXLValue) -> [Int] {
        switch value {
        case .integer(let number): [number]
        case .integers(let numbers): numbers
        case .real(let number): [Int(number)]
        case .reals(let numbers): numbers.map(Int.init)
        case .bytes: []
        }
    }
}
