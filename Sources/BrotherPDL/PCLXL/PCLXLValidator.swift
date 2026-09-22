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
        findings += endOfJob(stream)
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
        // The first ENTER LANGUAGE leaves PJL, so a second one is read as stream data, not as PJL.
        let entered = stream.pjlHeader.filter { $0.hasPrefix("@PJL ENTER LANGUAGE") }.count
        if entered > 1 {
            findings.append(.error("pjl-enter-language", "the PJL header enters a language \(entered) times"))
        }
        return findings
    }

    /// A job that opened with a name must close with an EOJ carrying it, or the printer's log and
    /// its accounting never see the job end.
    private static func endOfJob(_ stream: PCLXLStream) -> [PDLFinding] {
        guard let job = stream.pjlHeader.first(where: { $0.hasPrefix("@PJL JOB") }) else { return [] }
        let name = quotedName(of: job, keyword: "@PJL JOB NAME=")
        guard let eoj = stream.pjlTrailer.first(where: { $0.hasPrefix("@PJL EOJ") }) else {
            return [.error("pjl-eoj", "the job opens with \(quoted(job)) and never closes with an @PJL EOJ")]
        }
        let closing = quotedName(of: eoj, keyword: "@PJL EOJ NAME=")
        guard closing == name else {
            return [.error("pjl-eoj", "@PJL EOJ names \(quoted(closing ?? "")) where @PJL JOB named \(quoted(name ?? ""))")]
        }
        return []
    }

    private static func quotedName(of line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        let rest = line.dropFirst(keyword.count)
        guard rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") else { return nil }
        return String(rest.dropFirst().dropLast())
    }

    /// Reads `) HP-PCL XL;<major>;<minor>;<comment>`; defaults to 2.0 when it cannot be read.
    private static func protocolClass(_ header: String, into findings: inout [PDLFinding]) -> (major: Int, minor: Int) {
        let fields = header.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[0] == ") HP-PCL XL", let major = Int(fields[1]), let minor = Int(fields[2]) else {
            findings.append(.error("stream-header", "unreadable stream header \(quoted(header))"))
            return (2, 0)
        }
        // 2.0 and 2.1 are the classes this driver emits; anything else, negative minors included,
        // is a stream it did not write.
        if (major, minor) != (2, 0) && (major, minor) != (2, 1) {
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
    /// The unit `unitsPerMeasure` counts, also from BeginSession.
    private var measure = PCLXLMeasure.inch
    /// The sheet in user units, when BeginPage said which sheet it is.
    private var sheet: (width: Int, height: Int)?
    private var cursor: (x: Int, y: Int)?
    private var colorSpace: PCLXLColorSpace?
    /// Where the page's coordinate origin has been moved to, from SetPageOrigin.
    private var pageOrigin = (x: 0, y: 0)
    /// What PushGS saved, innermost last.
    private var graphicsState: [(cursor: (x: Int, y: Int)?, colorSpace: PCLXLColorSpace?, pageOrigin: (x: Int, y: Int))] = []

    /// What the open image declared, and how much of it has arrived.
    private struct Image {
        var width: Int
        var height: Int
        var bitsPerPixel: Int
        var rowsRead = 0

        /// The packed row, before any padding.
        var bytesPerRow: Int { (width * bitsPerPixel + 7) / 8 }
    }

    init(protocolClass: (major: Int, minor: Int)) {
        self.protocolClass = protocolClass
    }

    mutating func visit(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard let op = PCLXLOperator(rawValue: record.tag) else {
            // Telling a legal operator this driver does not model (SetPenWidth, say) from a tag no
            // printer assigns would need the whole operator table, which this project does not have
            // a source for. Either way it is not something this driver should be emitting, which is
            // what a warning means here — so it is reported without claiming the printer would balk.
            findings.append(
                .warning(
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
        if !graphicsState.isEmpty {
            findings.append(
                .warning("graphics-state", "\(graphicsState.count) PushGS without a matching PopGS"))
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
            measure = (record[.measure]?.intValue).flatMap { UInt8(exactly: $0) }.flatMap(PCLXLMeasure.init) ?? .inch
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
            // A page starts with a fresh graphics state: none of this carries over from the last one.
            cursor = nil
            colorSpace = nil
            pageOrigin = (0, 0)
            graphicsState = []
            sheet = sheetSize(record, into: &findings)
            // A landscape page is the same sheet turned on its side, so its bounds are too.
            let orientation = (record[.orientation]?.intValue).flatMap { UInt8(exactly: $0) }.flatMap(PCLXLOrientation.init)
            if orientation == .landscape || orientation == .reverseLandscape, let portrait = sheet {
                sheet = (width: portrait.height, height: portrait.width)
            }
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
            require(image == nil, "image", "SetCursor inside an image, where only image data may go")
            if let point = xy(record, .point) {
                cursor = point
            }

        case .setPageOrigin:
            require(pageOpen, "page", "SetPageOrigin outside a page")
            require(image == nil, "image", "SetPageOrigin inside an image, where only image data may go")
            // The new origin is given in the current coordinate system, so the shifts accumulate.
            if let point = xy(record, .point) {
                pageOrigin = (pageOrigin.x + point.x, pageOrigin.y + point.y)
            }

        case .setColorSpace:
            require(pageOpen, "page", "SetColorSpace outside a page")
            require(image == nil, "image", "SetColorSpace inside an image, where only image data may go")
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

        case .pushGS:
            require(image == nil, "image", "PushGS inside an image, where only image data may go")
            require(pageOpen, "page", "PushGS outside a page")
            graphicsState.append((cursor: cursor, colorSpace: colorSpace, pageOrigin: pageOrigin))

        case .popGS:
            require(image == nil, "image", "PopGS inside an image, where only image data may go")
            require(pageOpen, "page", "PopGS outside a page")
            guard let restored = graphicsState.popLast() else {
                require(false, "graphics-state", "PopGS with nothing pushed underflows the printer's stack")
                break
            }
            cursor = restored.cursor
            colorSpace = restored.colorSpace
            pageOrigin = restored.pageOrigin

        case .comment:
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
            guard let sizeUnits = UInt8(exactly: units).flatMap(PCLXLMeasure.init) else { return nil }
            // CustomMediaSize has its own unit, which is not necessarily the session's Measure.
            let perInch = Self.measuresPerInch(sizeUnits)
            return (
                self.units(points: Double(size.x) * 72 / perInch, along: .x),
                self.units(points: Double(size.y) * 72 / perInch, along: .y)
            )
        }
    }

    /// Points into the session's user units. `UnitsPerMeasure` counts units per `Measure`, so a
    /// session measured in millimetres has ~25.4 times as many measures to an inch as one in inches.
    private func units(points: Double, along axis: Axis) -> Int {
        let perMeasure = axis == .x ? unitsPerMeasure.x : unitsPerMeasure.y
        return Int((points / 72 * Self.measuresPerInch(measure) * Double(perMeasure)).rounded())
    }

    static func measuresPerInch(_ measure: PCLXLMeasure) -> Double {
        switch measure {
        case .inch: 1
        case .millimeter: 25.4
        case .tenthsOfAMillimeter: 254
        }
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
            let left = pageOrigin.x + cursor.x
            let top = pageOrigin.y + cursor.y
            let right = left + destination.x
            let bottom = top + destination.y
            if left < 0 || top < 0 || right > sheet.width || bottom > sheet.height {
                findings.append(
                    .error(
                        "image-off-sheet",
                        "image covers \(left),\(top)–\(right),\(bottom) of a \(sheet.width)×\(sheet.height) sheet",
                        at: record.offset))
            }
        }
        let depth = record[.colorDepth]?.intValue
        let bitsPerComponent = depth == Int(PCLXLColorDepth.bits8.rawValue) ? 8 : depth == Int(PCLXLColorDepth.bits4.rawValue) ? 4 : 1
        // An indexed image carries one index per pixel whatever the colour space; a direct one
        // carries a component per channel. At 1 or 4 bits a pixel is narrower than a byte, so the
        // row is measured in bits and rounded up once, at the end.
        let indexed = record[.colorMapping]?.intValue == Int(PCLXLColorMapping.indexedPixel.rawValue)
        let components = indexed || colorSpace == .gray ? 1 : 3
        image = Image(width: width, height: height, bitsPerPixel: bitsPerComponent * components)
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
            if mode == .none, let data = record.data, state.bitsPerPixel > 0 {
                // Uncompressed rows are padded to a multiple of PadBytesMultiple, four by default,
                // so the block's size is exact.
                let multiple = record[.padBytesMultiple]?.intValue ?? 4
                let bytesPerRow = state.bytesPerRow
                let padded = multiple > 0 ? (bytesPerRow + multiple - 1) / multiple * multiple : bytesPerRow
                let blockHeight = record[.blockHeight]?.intValue ?? 0
                if data.count != padded * blockHeight {
                    findings.append(
                        .error(
                            "image-data-length",
                            "uncompressed block carries \(data.count) bytes, not the \(padded * blockHeight) "
                                + "that \(blockHeight) rows of \(state.width) pixels at \(state.bitsPerPixel) bits need",
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

    /// An xy pair, whichever numeric shape it was sent in. A real is rounded; one no `Int` can hold
    /// is treated as absent, because the attribute rules have already reported it.
    private func xy(_ record: PCLXLOperatorRecord, _ attribute: PCLXLAttribute) -> (x: Int, y: Int)? {
        switch record[attribute] {
        case .integers(let values) where values.count == 2:
            return (values[0], values[1])
        case .reals(let values) where values.count == 2:
            guard let x = Int(exactly: values[0].rounded()), let y = Int(exactly: values[1].rounded()) else { return nil }
            return (x, y)
        default:
            return nil
        }
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
            for number in numbers(of: attribute.value) {
                guard let value = number else {
                    findings.append(
                        .error("attribute-value", "\(label(attribute)) is not a number any printer could use", at: attribute.offset))
                    break
                }
                if !range.contains(value) || spec.excluding.contains(value) {
                    findings.append(
                        .error(
                            "attribute-value", "\(label(attribute)) is \(value), outside \(range.lowerBound)…\(range.upperBound)",
                            at: attribute.offset))
                    break
                }
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

    /// The integers in a value, for range checking. A `real32` that no `Int` can represent — NaN,
    /// an infinity, something astronomically large — is reported by the caller as out of range
    /// rather than converted, because converting it would trap on a job this tool is meant to
    /// survive reading.
    private func numbers(of value: PCLXLValue) -> [Int?] {
        switch value {
        case .integer(let number): [number]
        case .integers(let numbers): numbers
        case .real(let number): [Int(exactly: number.rounded())]
        case .reals(let numbers): numbers.map { Int(exactly: $0.rounded()) }
        case .bytes: []
        }
    }
}
