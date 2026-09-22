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
        if bytes.starts(with: PCLXLReader.uel), stream.pjlHeader.isEmpty {
            // The opening UEL puts the printer into PJL. With no @PJL line after it, nothing ever
            // takes it back out, so the stream that follows is read as PJL rather than as PCL XL.
            findings.append(
                .error("pjl-enter-language", "the job opens with a UEL and no PJL, so nothing enters PCL XL", at: 0))
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
        // An unquoted name reads as nil, and two nils are not a match: comparing them first would
        // let a pair of malformed lines pass as a well-formed job.
        guard let name else {
            return [.error("pjl-eoj", "cannot read the job name from \(quoted(job))")]
        }
        guard let closing else {
            return [.error("pjl-eoj", "cannot read the job name from \(quoted(eoj))")]
        }
        guard closing == name else {
            return [.error("pjl-eoj", "@PJL EOJ names \(quoted(closing)) where @PJL JOB named \(quoted(name))")]
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
        // A negative version is not a protocol class at all, so a printer rejects the stream. A
        // positive one this driver does not emit is legal PCL XL, which is a warning here.
        if major < 0 || minor < 0 {
            findings.append(.error("stream-header", "protocol class \(major).\(minor) is not a version"))
        } else if (major, minor) != (2, 0) && (major, minor) != (2, 1) {
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
    private var unitsPerMeasure = (x: 0.0, y: 0.0)
    /// The unit `unitsPerMeasure` counts, also from BeginSession.
    private var measure = PCLXLMeasure.inch
    /// The sheet in user units, when BeginPage said which sheet it is.
    private var sheet: (width: Double, height: Double)?
    private var cursor: (x: Double, y: Double)?
    private var colorSpace: PCLXLColorSpace?
    /// The side the last duplex page declared, to check that the next one turns over.
    private var lastDuplexSide: Int?
    /// Attribute ids the schema rejected on the record being visited. Reading one of these back
    /// for a semantic check means deriving geometry from a number the printer would never have
    /// read — which is how a `uint32` width of 4294967295 reached the stride arithmetic.
    private var rejected: Set<UInt8> = []
    /// Where the page's coordinate origin has been moved to, from SetPageOrigin.
    private var pageOrigin = (x: 0.0, y: 0.0)
    /// Whether the page's coordinate system is still one this validator has followed. An operator
    /// it does not model may be a scale or a rotation, and there is no way to tell from the tag
    /// alone. Once one has gone past, bounds arithmetic is arithmetic about a page that no longer
    /// exists, so the sheet checks stop rather than carry on confidently.
    private var geometryFollowed = true
    /// What PushGS saved, innermost last.
    private var graphicsState:
        [(cursor: (x: Double, y: Double)?, colorSpace: PCLXLColorSpace?, pageOrigin: (x: Double, y: Double))] = []

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
            if pageOpen && geometryFollowed {
                geometryFollowed = false
                findings.append(
                    .coverage(
                        "image-off-sheet",
                        "operator 0x\(String(record.tag, radix: 16)) may move or scale the page, so where the "
                            + "rest of this page's images land is no longer checked",
                        at: record.offset))
            }
            // Where it sits is a separate question from what it is: an operator of any kind after
            // EndSession is outside the session, and saying so does not depend on naming it.
            if sessionEnded {
                findings.append(
                    .error("session", "an operator comes after EndSession", at: record.offset))
            } else if !sessionOpen {
                findings.append(.error("session", "an operator appears outside a session", at: record.offset))
            }
            return
        }
        rejected =
            OperatorSpec.all[op]?
            .check(record, named: String(describing: op), class: protocolClass, into: &findings) ?? []
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
            measure = (accepted(record, .measure)?.intValue).flatMap { UInt8(exactly: $0) }.flatMap(PCLXLMeasure.init) ?? .inch
            if unitsPerMeasure.x != unitsPerMeasure.y {
                findings.append(
                    .warning(
                        "units-per-measure",
                        "UnitsPerMeasure is \(Self.number(unitsPerMeasure.x))×\(Self.number(unitsPerMeasure.y)); "
                            + "this driver sends square units",
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
            // Code 13 ("eB5Paper") is a defined class-2.1 spelling of JIS B5, which a printer
            // accepts; this driver sends code 11 for the same sheet, so seeing 13 says the job
            // came from somewhere else rather than that it will be rejected.
            if accepted(record, .mediaSize)?.intValue == 13 {
                findings.append(
                    .warning(
                        "media-size", "MediaSize 13 is eB5Paper; this driver spells JIS B5 as 11",
                        at: record.offset))
            }
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
            geometryFollowed = true
            sheet = sheetSize(record, into: &findings)
            // A landscape page is the same sheet turned on its side, so its bounds are too.
            let orientation = (accepted(record, .orientation)?.intValue)
                .flatMap { UInt8(exactly: $0) }.flatMap(PCLXLOrientation.init)
            if orientation == .landscape || orientation == .reverseLandscape, let portrait = sheet {
                sheet = (width: portrait.height, height: portrait.width)
            }
            duplexAttributes(record, into: &findings)

        case .endPage:
            require(pageOpen, "page", "EndPage without BeginPage")
            require(image == nil, "image", "EndPage inside an image")
            if images == 0 {
                // A page with nothing on it is a blank sheet, which is what the printer should receive when
                // the rasteriser pads a duplex job to an even page count — and also what it receives when a
                // page's raster was dropped. Nothing in the job distinguishes the two, so this reports the
                // fact without calling it a fault.
                findings.append(.coverage("page", "page \(pages) carries no images", at: record.offset))
            }
            if let copies = accepted(record, .pageCopies)?.intValue, copies != 1 {
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
            if let point = xy(record, .pageOrigin) {
                pageOrigin = (pageOrigin.x + point.x, pageOrigin.y + point.y)
            }

        case .setColorSpace:
            require(pageOpen, "page", "SetColorSpace outside a page")
            require(image == nil, "image", "SetColorSpace inside an image, where only image data may go")
            colorSpace = (accepted(record, .colorSpace)?.intValue).flatMap { UInt8(exactly: $0) }.flatMap(PCLXLColorSpace.init)

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
    ) -> (width: Double, height: Double)? {
        let standard = accepted(record, .mediaSize)?.intValue
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
            guard let units = accepted(record, .customMediaSizeUnits)?.intValue else {
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
                self.units(points: size.x * 72 / perInch, along: .x),
                self.units(points: size.y * 72 / perInch, along: .y)
            )
        }
    }

    /// Points into the session's user units. `UnitsPerMeasure` counts units per `Measure`, so a
    /// session measured in millimetres has ~25.4 times as many measures to an inch as one in inches.
    private func units(points: Double, along axis: Axis) -> Double {
        let perMeasure = axis == .x ? unitsPerMeasure.x : unitsPerMeasure.y
        return points / 72 * Self.measuresPerInch(measure) * perMeasure
    }

    static func measuresPerInch(_ measure: PCLXLMeasure) -> Double {
        switch measure {
        case .inch: 1
        case .millimeter: 25.4
        case .tenthsOfAMillimeter: 254
        }
    }

    private enum Axis { case x, y }

    /// Whole numbers without a decimal tail, which is what these nearly always are.
    static func number(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15 ? String(Int(value)) : String(value)
    }

    private mutating func duplexAttributes(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        // Consecutive duplex pages are the two sides of one sheet, so they have to alternate.
        // Repeating a side prints them on separate sheets, and every page on its own is valid.
        if let side = accepted(record, .duplexPageSide)?.intValue {
            if let last = lastDuplexSide, last == side {
                findings.append(
                    .warning(
                        "duplex", "two duplex pages in a row declare the same side, so they will not share a sheet",
                        at: record.offset))
            }
            lastDuplexSide = side
        } else {
            lastDuplexSide = nil
        }
        duplexModes(record, into: &findings)
    }

    private func duplexModes(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        let simplex = accepted(record, .simplexPageMode) != nil
        let duplex = accepted(record, .duplexPageMode) != nil
        if simplex && duplex {
            findings.append(
                .error("duplex", "BeginPage sends both SimplexPageMode and DuplexPageMode", at: record.offset))
        }
        if accepted(record, .duplexPageSide) != nil && !duplex {
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
        guard let width = accepted(record, .sourceWidth)?.intValue, let height = accepted(record, .sourceHeight)?.intValue,
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
        // Source size is in pixels and destination in user units, so they are only comparable
        // because this driver never scales — which is exactly what is being checked.
        if destination.x != Double(width) || destination.y != Double(height) {
            findings.append(
                .warning(
                    "image-scale",
                    "image is \(width)×\(height) into \(Self.number(destination.x))×\(Self.number(destination.y)) "
                        + "user units; this driver never scales",
                    at: record.offset))
        }
        // PCL XL clips painting to the active clipping region rather than refusing the job, so an
        // image reaching past the sheet is not by itself a malformed stream — the printer prints
        // what falls inside. It is still not something this driver means to emit: every image it
        // places is a page of raster that should land on the paper, and one that does not is a
        // margin or origin bug whose visible symptom is a silently cropped page. So this is a
        // policy finding, which `--fail-on policy` makes fatal for jobs this driver wrote.
        if let sheet, geometryFollowed {
            let left = pageOrigin.x + cursor.x
            let top = pageOrigin.y + cursor.y
            let right = left + destination.x
            let bottom = top + destination.y
            if left < 0 || top < 0 || right > sheet.width || bottom > sheet.height {
                findings.append(
                    .warning(
                        "image-off-sheet",
                        "image covers \(Self.number(left)),\(Self.number(top))–\(Self.number(right)),\(Self.number(bottom)) "
                            + "of a \(Self.number(sheet.width))×\(Self.number(sheet.height)) sheet, so the printer "
                            + "will clip it",
                        at: record.offset))
            }
        }
        let depth = accepted(record, .colorDepth)?.intValue
        let bitsPerComponent =
            depth == Int(PCLXLColorDepth.bits8.rawValue)
            ? 8 : depth == Int(PCLXLColorDepth.bits4.rawValue) ? 4 : 1
        // An indexed image carries one index per pixel whatever the colour space; a direct one
        // carries a component per channel. At 1 or 4 bits a pixel is narrower than a byte, so the
        // row is measured in bits and rounded up once, at the end.
        let indexed = accepted(record, .colorMapping)?.intValue == Int(PCLXLColorMapping.indexedPixel.rawValue)
        let components = indexed || colorSpace == .gray ? 1 : 3
        image = Image(width: width, height: height, bitsPerPixel: bitsPerComponent * components)
    }

    /// What a compressed ReadImage block would decode to, measured rather than produced.
    ///
    /// The obvious implementation — decode the block and take `count` — asks the decoders to
    /// allocate the image in order to ask how big it is, and the attributes that decide that size
    /// come from the job. `SourceWidth` and `BlockHeight` of 65535 are both in range, and at RGB
    /// 8-bit they make a 131 KB payload demand a 12 GiB output buffer. A validator that a
    /// malformed job can make exhaust memory is not a check, it is a second way to fail.
    ///
    /// So these walk the encoding and count. Neither allocates anything proportional to the
    /// output, and both stop as soon as the answer is settled.
    private enum BlockSize {
        /// Decodes to exactly this many bytes.
        case exact(Int)
        /// Reaches at least this many bytes; counting stopped once that was enough to judge.
        case atLeast(Int)
        /// Does not decode: truncated, or a command that runs off the end of a row.
        case malformed
    }

    /// Counts RLE output without building it. The format is literal and repeat packets, so the
    /// output length is a sum of packet lengths; nothing needs to be held.
    private func rleSize(_ data: [UInt8], upTo limit: Int) -> BlockSize {
        var index = 0
        var produced = 0
        while index < data.count {
            let control = Int(data[index])
            index += 1
            if control < 128 {
                let length = control + 1
                guard index + length <= data.count else { return .malformed }
                index += length
                produced += length
            } else if control > 128 {
                guard index < data.count else { return .malformed }
                index += 1
                produced += 257 - control
            }
            if produced >= limit { return .atLeast(produced) }
        }
        return .exact(produced)
    }

    /// Walks DeltaRow's row structure without keeping a seed row or any output. Each row is a
    /// two-byte length and then commands that write inside `bytesPerRow`; the rows themselves are
    /// whatever the seed becomes, so counting them is enough to know the output size.
    private func deltaRowSize(_ data: [UInt8], bytesPerRow: Int, rows: Int) -> BlockSize {
        guard bytesPerRow > 0 else { return .malformed }
        var cursor = 0
        for _ in 0..<rows {
            guard cursor + 2 <= data.count else { return .malformed }
            let length = Int(data[cursor]) | Int(data[cursor + 1]) << 8
            cursor += 2
            guard cursor + length <= data.count else { return .malformed }

            let end = cursor + length
            var index = cursor
            var position = 0
            while index < end {
                let command = Int(data[index])
                index += 1
                let replacements = (command >> 5) + 1
                var offset = command & 31
                if offset == 31 {
                    while true {
                        guard index < end else { return .malformed }
                        let extra = Int(data[index])
                        index += 1
                        offset += extra
                        if extra != 255 { break }
                    }
                }
                position += offset
                guard position + replacements <= bytesPerRow, index + replacements <= end else {
                    return .malformed
                }
                index += replacements
                position += replacements
            }
            cursor = end
        }
        // The decoder insists the block holds these rows and nothing else.
        guard cursor == data.count else { return .malformed }
        return .exact(bytesPerRow * rows)
    }

    private mutating func readImage(_ record: PCLXLOperatorRecord, into findings: inout [PDLFinding]) {
        guard var state = image else {
            findings.append(.error("image", "ReadImage outside an image", at: record.offset))
            return
        }
        defer { image = state }

        if let mode = (accepted(record, .compressMode)?.intValue).flatMap({ UInt8(exactly: $0) }).flatMap(PCLXLCompressMode.init) {
            // DeltaRow is the compression class 2.1 added. JPEG is class 2.0 — pairing the two
            // here was wrong, and made a legal 2.0 JPEG stream look rejectable.
            if mode == .deltaRow && (protocolClass.major, protocolClass.minor) < (2, 1) {
                findings.append(
                    .error(
                        "compress-mode-class",
                        "CompressMode \(mode) needs protocol class 2.1; the stream header declares "
                            + "\(protocolClass.major).\(protocolClass.minor)",
                        at: record.offset))
            }
            if let data = record.data, state.bitsPerPixel > 0, let blockHeight = accepted(record, .blockHeight)?.intValue,
                blockHeight > 0
            {
                // Rows are padded to a multiple of PadBytesMultiple, four by default. RLE carries
                // the padding through the compressed stream; DeltaRow does not, because its rows
                // are length-prefixed. (GhostPCL pads the one and not the other, the same way.)
                let multiple = accepted(record, .padBytesMultiple)?.intValue ?? 4
                let bytesPerRow = state.bytesPerRow
                let padded = multiple > 0 ? (bytesPerRow + multiple - 1) / multiple * multiple : bytesPerRow
                let stride = mode == .deltaRow ? bytesPerRow : padded
                // Every factor here came out of the job, so the product is checked rather than
                // assumed: a block the arithmetic cannot describe is one the printer cannot
                // reconstruct either, and saying so beats trapping on it.
                let (needed, overflowed) = stride.multipliedReportingOverflow(by: blockHeight)
                guard !overflowed else {
                    findings.append(
                        .error(
                            "image-data-length",
                            "\(blockHeight) rows of \(state.width) pixels at \(state.bitsPerPixel) bits is "
                                + "more image than any printer can hold",
                            at: record.offset))
                    return
                }
                switch mode {
                case .none:
                    // Uncompressed data is the rows themselves, so the block's size is exact.
                    if data.count != needed {
                        findings.append(
                            .error(
                                "image-data-length",
                                "uncompressed block carries \(data.count) bytes, not the \(needed) "
                                    + "that \(blockHeight) rows of \(state.width) pixels at "
                                    + "\(state.bitsPerPixel) bits need",
                                at: record.offset))
                    }
                case .rle, .deltaRow:
                    // A compressed block's declared height is only a claim until the block is
                    // read: an empty or truncated one satisfies every count in the stream while
                    // leaving the printer nothing to reconstruct the rows from.
                    let size =
                        mode == .rle
                        ? rleSize(data, upTo: needed)
                        : deltaRowSize(data, bytesPerRow: bytesPerRow, rows: blockHeight)
                    switch size {
                    case .atLeast:
                        // Enough, and possibly more. Excess RLE output is not treated as fatal:
                        // no interpreter evidence here says a printer rejects a block that
                        // decodes long, only that one decoding short cannot fill the rows.
                        break
                    case .exact(let produced) where produced >= needed:
                        break
                    case .exact(let produced):
                        findings.append(
                            .error(
                                "image-data-length",
                                "\(mode) block holds \(produced) bytes of image, not the \(needed) that "
                                    + "\(blockHeight) rows of \(state.width) pixels at "
                                    + "\(state.bitsPerPixel) bits need",
                                at: record.offset))
                    case .malformed:
                        findings.append(
                            .error(
                                "image-data-length",
                                "\(mode) block does not decode: the printer cannot reconstruct the "
                                    + "\(blockHeight) rows it declares",
                                at: record.offset))
                    }
                case .jpeg:
                    // Nothing here reads JPEG. Saying so is a coverage note, not a verdict: the
                    // mode is legal in class 2.0 and the block may be perfectly well formed.
                    findings.append(
                        .coverage(
                            "image-data-length", "a JPEG block's size is not checked here", at: record.offset))
                }
            }
        }
        if record.data == nil {
            findings.append(.error("image-data", "ReadImage carries no data block", at: record.offset))
        }

        guard let startLine = accepted(record, .startLine)?.intValue,
            let blockHeight = accepted(record, .blockHeight)?.intValue
        else {
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

    /// An attribute's value, or nil when the schema already rejected it.
    private func accepted(_ record: PCLXLOperatorRecord, _ attribute: PCLXLAttribute) -> PCLXLValue? {
        rejected.contains(attribute.rawValue) ? nil : record[attribute]
    }

    /// An xy pair, whichever numeric shape it was sent in, kept as written. Rounding each
    /// component before the bounds arithmetic would move the edges: a cursor at 5098.5 with a
    /// destination 1.5 wide ends exactly on a 5100-unit sheet, where 5099 plus 2 is off it.
    /// A non-finite real is treated as absent, since the attribute rules have already reported it.
    private func xy(_ record: PCLXLOperatorRecord, _ attribute: PCLXLAttribute) -> (x: Double, y: Double)? {
        switch accepted(record, attribute) {
        case .integers(let values) where values.count == 2:
            return (Double(values[0]), Double(values[1]))
        case .reals(let values) where values.count == 2:
            guard values[0].isFinite, values[1].isFinite else { return nil }
            return (Double(values[0]), Double(values[1]))
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
    /// Legal values in protocol class 2.0, for the scalar attributes whose range is fixed. Nil
    /// leaves the value unchecked.
    var values: ClosedRange<Int>?
    /// Values inside `values` that are nonetheless not defined, e.g. gaps in an enumeration.
    var excluding: Set<Int> = []
    var required: Bool
    /// Values class 2.1 adds. A stream that declares 2.0 may not use them; one that declares 2.1
    /// may, and a validator that ignores the distinction either rejects legal 2.1 jobs or accepts
    /// values the 2.0 interpreter has never heard of.
    var addedIn21: Set<Int> = []
    /// Whether class 2.1 stops requiring the attribute.
    var optionalIn21: Bool = false

    static func required(
        _ attribute: PCLXLAttribute, _ tags: Set<PCLXLDataTag>, _ values: ClosedRange<Int>? = nil,
        excluding: Set<Int> = [], addedIn21: Set<Int> = [], optionalIn21: Bool = false
    ) -> Self {
        Self(
            attribute: attribute, tags: tags, values: values, excluding: excluding, required: true,
            addedIn21: addedIn21, optionalIn21: optionalIn21)
    }

    static func optional(
        _ attribute: PCLXLAttribute, _ tags: Set<PCLXLDataTag>, _ values: ClosedRange<Int>? = nil,
        excluding: Set<Int> = [], addedIn21: Set<Int> = []
    ) -> Self {
        Self(
            attribute: attribute, tags: tags, values: values, excluding: excluding, required: false,
            addedIn21: addedIn21)
    }

    /// Whether `value` is one this attribute may carry in a stream of the given class.
    func allows(_ value: Int, in protocolClass: (major: Int, minor: Int)) -> Bool {
        if (protocolClass.major, protocolClass.minor) >= (2, 1), addedIn21.contains(value) { return true }
        guard let values else { return true }
        return values.contains(value) && !excluding.contains(value)
    }

    func isRequired(in protocolClass: (major: Int, minor: Int)) -> Bool {
        required && !(optionalIn21 && (protocolClass.major, protocolClass.minor) >= (2, 1))
    }
}

/// Data-type groups, named once so the operator table stays readable.
/// The data types each attribute is sent in.
///
/// These are per attribute, not one permissive "any XY" group, because HP's schemas are per
/// attribute: `DestinationSize` takes `uint16XY` and nothing else, while `CustomMediaSize` also
/// takes `real32XY`. A shared group that admits every XY shape does not make the validator more
/// tolerant of real jobs — it makes it accept encodings no printer is documented to read, which
/// is the opposite of what a preflight is for.
private enum Tags {
    static let ubyte: Set<PCLXLDataTag> = [.ubyte]
    static let uint16: Set<PCLXLDataTag> = [.ubyte, .uint16]
    /// `Point` and `PageOrigin`: a signed position, in the three widths HP lists.
    static let positionXY: Set<PCLXLDataTag> = [.ubyteXY, .uint16XY, .sint16XY]
    /// `DestinationSize`.
    static let uint16XY: Set<PCLXLDataTag> = [.uint16XY]
    /// `CustomMediaSize`, which may be fractional.
    static let mediaXY: Set<PCLXLDataTag> = [.uint16XY, .real32XY]
    /// `UnitsPerMeasure`. Not narrowed against the schema the way the four above have been, so it
    /// stays as it was rather than gaining a restriction nobody has checked.
    static let unsignedXY: Set<PCLXLDataTag> = [.ubyteXY, .uint16XY, .uint32XY, .real32XY]
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
            // 0…3 plus NullReporter, BackChannel and ErrorPage variants: 4…6 are class 2.0 too.
            .optional(.errorReport, Tags.ubyte, 0...6),
        ]),
        .endSession: OperatorSpec(attributes: []),
        .openDataSource: OperatorSpec(attributes: [
            .required(.sourceType, Tags.ubyte, 0...0),
            .required(.dataOrg, Tags.ubyte, 0...1),
        ]),
        .closeDataSource: OperatorSpec(attributes: []),
        .beginPage: OperatorSpec(attributes: [
            // Class 2.1 adds eDefaultOrientation (4) and stops requiring the attribute at all.
            .required(.orientation, Tags.ubyte, 0...3, addedIn21: [4], optionalIn21: true),
            // 13 (eB5Paper), 19, 20, 21 and 96 are class 2.1 additions, so a 2.0 stream may not
            // use them. This driver spells JIS B5 as 11 whatever the class.
            .optional(.mediaSize, Tags.ubyte, 0...18, excluding: [13], addedIn21: [13, 19, 20, 21, 96]),
            .optional(.customMediaSize, Tags.mediaXY, 1...65535),
            .optional(.customMediaSizeUnits, Tags.ubyte, 0...2),
            // 0…7 are the named sources; 8…255 are the external trays, which a printer with a
            // finisher really does use.
            .optional(.mediaSource, Tags.ubyte, 0...255),
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
            .required(.point, Tags.positionXY)
        ]),
        .setPageOrigin: OperatorSpec(attributes: [
            .required(.pageOrigin, Tags.positionXY)
        ]),
        .beginImage: OperatorSpec(attributes: [
            .required(.colorMapping, Tags.ubyte, 0...1),
            .required(.colorDepth, Tags.ubyte, 0...2),
            .required(.sourceWidth, Tags.uint16, 1...65535),
            .required(.sourceHeight, Tags.uint16, 1...65535),
            .required(.destinationSize, Tags.uint16XY, 1...65535),
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
    ///
    /// Returns the ids of the attributes it rejected, so the semantic checks that follow do not
    /// compute geometry from a value the schema has already said is not one a printer reads.
    @discardableResult
    func check(
        _ record: PCLXLOperatorRecord, named name: String, class protocolClass: (major: Int, minor: Int),
        into findings: inout [PDLFinding]
    ) -> Set<UInt8> {
        var seen: Set<UInt8> = []
        var rejected: Set<UInt8> = []

        for attribute in record.attributes {
            guard seen.insert(attribute.id).inserted else {
                findings.append(
                    .error("attribute-duplicate", "\(name) sends \(label(attribute)) twice", at: attribute.offset))
                continue
            }
            guard let spec = attributes.first(where: { $0.attribute.rawValue == attribute.id }) else {
                findings.append(
                    .error("attribute-unknown", "\(name) does not take \(label(attribute))", at: attribute.offset))
                rejected.insert(attribute.id)
                continue
            }
            guard spec.tags.contains(attribute.tag) else {
                findings.append(
                    .error(
                        "attribute-type",
                        "\(label(attribute)) is sent as \(attribute.tag), which \(name) does not accept",
                        at: attribute.offset))
                rejected.insert(attribute.id)
                continue
            }
            guard spec.values != nil else { continue }
            for number in numbers(of: attribute.value) {
                guard let value = number else {
                    findings.append(
                        .error("attribute-value", "\(label(attribute)) is not a number any printer could use", at: attribute.offset))
                    rejected.insert(attribute.id)
                    break
                }
                if !spec.allows(value, in: protocolClass) {
                    findings.append(
                        .error(
                            "attribute-value",
                            "\(label(attribute)) is \(value), which protocol class "
                                + "\(protocolClass.major).\(protocolClass.minor) does not define for it",
                            at: attribute.offset))
                    rejected.insert(attribute.id)
                    break
                }
            }
        }

        for spec in attributes
        where spec.isRequired(in: protocolClass) && !seen.contains(spec.attribute.rawValue) {
            findings.append(
                .error("attribute-missing", "\(name) is missing \(spec.attribute)", at: record.offset))
        }
        return rejected
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
