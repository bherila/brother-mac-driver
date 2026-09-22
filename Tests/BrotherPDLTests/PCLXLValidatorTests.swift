import Testing

@testable import BrotherPDL

// A validator is only as good as the damage it notices, so every check here starts from a job the
// real backend produced and breaks exactly one thing in it.

// MARK: - Helpers

/// A job from the real encoder: `pages` pages of `width` × `height`, each with a black square.
private func goodJob(
    pages: Int = 1, width: Int = 64, height: Int = 200, format: PixelFormat = .gray8,
    options: JobOptions = JobOptions()
) throws -> [UInt8] {
    var sink = ByteBuffer()
    var backend = PCLXLBackend(options: options)
    let geometry = PageGeometry(width: width, height: height, dpi: 600, format: format)
    var row = [UInt8](repeating: 0xFF, count: geometry.bytesPerRow)
    for index in 0..<min(geometry.bytesPerRow, 30) { row[index] = 0x20 }

    try backend.beginJob(to: &sink)
    for _ in 0..<pages {
        try backend.beginPage(geometry, to: &sink)
        for _ in 0..<height {
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        try backend.endPage(to: &sink)
    }
    try backend.endJob(to: &sink)
    return sink.bytes
}

/// The rules reported, in order, so a test can name what it expects to be told.
private func rules(_ findings: [PDLFinding]) -> [String] {
    findings.map(\.rule)
}

private func errors(_ findings: [PDLFinding]) -> [PDLFinding] {
    findings.filter { $0.severity == .error }
}

/// Replaces the first occurrence of `pattern` in `job`, which must be there.
private func patched(_ job: [UInt8], replacing pattern: [UInt8], with replacement: [UInt8]) -> [UInt8] {
    guard let range = job.firstRange(of: pattern) else {
        Issue.record("pattern \(pattern) is not in the job")
        return job
    }
    var copy = job
    copy.replaceSubrange(range, with: replacement)
    return copy
}

private func patched(_ job: [UInt8], replacing text: String, with replacement: String) -> [UInt8] {
    patched(job, replacing: Array(text.utf8), with: Array(replacement.utf8))
}

/// The attribute byte sequence for a ubyte attribute, as the writer emits it.
private func ubyteAttribute(_ value: UInt8, _ attribute: PCLXLAttribute) -> [UInt8] {
    [PCLXLDataTag.ubyte.rawValue, value, PCLXLStructureTag.attributeUByte, attribute.rawValue]
}

// MARK: - A good job passes

@Suite struct PCLXLValidatorCleanJobTests {
    @Test func aJobFromTheEncoderHasNothingWrongWithIt() throws {
        let findings = PCLXLValidator.check(job: try goodJob())
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test(arguments: [1, 2, 3]) func multiPageJobsPass(pages: Int) throws {
        let findings = PCLXLValidator.check(job: try goodJob(pages: pages))
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func colourDuplexAndTrayOptionsPass() throws {
        var options = JobOptions()
        options.duplex = .longEdge
        options.inputSlot = .tray2
        options.colorMode = .color
        options.jobName = "validator test"
        let findings = PCLXLValidator.check(job: try goodJob(pages: 2, format: .rgb8, options: options))
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func aDeltaRowJobDeclaresProtocolClass21() throws {
        var options = JobOptions()
        options.compression = .deltaRow
        let job = try goodJob(options: options)
        #expect(try PCLXLReader.parse(job).streamHeader.hasPrefix(") HP-PCL XL;2;1;"))
        #expect(PCLXLValidator.check(job: job).isEmpty)
    }

    @Test func aRealMediaSizeAndCustomSizePass() throws {
        // Letter, declared by its MediaSize code, with the raster inset by a 12 pt margin.
        var geometry = PageGeometry(
            width: 4900, height: 6400, dpi: 600, format: .gray8,
            mediaPoints: .init(width: 612, height: 792), origin: .init(x: 100, y: 100))
        var findings = PCLXLValidator.check(job: try job(geometry))
        #expect(findings.isEmpty, "\(findings)")

        // 3 × 5 in has no MediaSize code, so it goes out as CustomMediaSize.
        geometry = PageGeometry(
            width: 1600, height: 2800, dpi: 600, format: .gray8,
            mediaPoints: .init(width: 216, height: 360), origin: .init(x: 100, y: 100))
        findings = PCLXLValidator.check(job: try job(geometry))
        #expect(findings.isEmpty, "\(findings)")
    }

    private func job(_ geometry: PageGeometry) throws -> [UInt8] {
        var sink = ByteBuffer()
        var backend = PCLXLBackend(options: JobOptions())
        var row = [UInt8](repeating: 0xFF, count: geometry.bytesPerRow)
        row[10] = 0
        try backend.beginJob(to: &sink)
        try backend.beginPage(geometry, to: &sink)
        for _ in 0..<geometry.height {
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        try backend.endPage(to: &sink)
        try backend.endJob(to: &sink)
        return sink.bytes
    }
}

// MARK: - Framing and the PJL wrapper

@Suite struct PCLXLValidatorFramingTests {
    @Test func aJobThatDoesNotEndWithAUELIsReported() throws {
        let job = try goodJob().dropLast(3)
        #expect(rules(PCLXLValidator.check(job: Array(job))).contains("framing"))
    }

    @Test func trailingNewlinesAfterTheUELAreFine() throws {
        let findings = PCLXLValidator.check(job: try goodJob() + Array("\n".utf8))
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func aStreamWithoutTheEnterLanguageLineIsReported() throws {
        let job = patched(
            try goodJob(), replacing: Array("@PJL ENTER LANGUAGE=PCLXL\n".utf8),
            with: Array("@PJL ENTER LANGUAGE=PCL\n".utf8))
        #expect(rules(PCLXLValidator.check(job: job)).contains("pjl-enter-language"))
    }

    @Test func anUnreadableStreamHeaderIsReported() throws {
        let job = patched(
            try goodJob(), replacing: Array(") HP-PCL XL;2;0;".utf8), with: Array(") BROTHER XL2HB;;;".utf8))
        #expect(rules(PCLXLValidator.check(job: job)).contains("stream-header"))
    }
}

// MARK: - Attribute rules

@Suite struct PCLXLValidatorAttributeTests {
    @Test func anAttributeTheOperatorDoesNotTakeIsReported() throws {
        // ErrorReport belongs on BeginSession; on BeginPage a printer rejects it.
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .orientation),
            with: ubyteAttribute(0, .orientation) + ubyteAttribute(1, .errorReport))
        let findings = PCLXLValidator.check(job: job)
        #expect(rules(findings).contains("attribute-unknown"))
    }

    @Test func aRepeatedAttributeIsReported() throws {
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .orientation),
            with: ubyteAttribute(0, .orientation) + ubyteAttribute(0, .orientation))
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-duplicate"))
    }

    @Test func aMissingRequiredAttributeIsReported() throws {
        let job = patched(try goodJob(), replacing: ubyteAttribute(0, .orientation), with: [])
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-missing"))
    }

    @Test func anAttributeSentWithTheWrongDataTypeIsReported() throws {
        // Orientation as uint16 rather than ubyte: the value is right, the type is not.
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .orientation),
            with: [PCLXLDataTag.uint16.rawValue, 0, 0, PCLXLStructureTag.attributeUByte, PCLXLAttribute.orientation.rawValue])
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-type"))
    }

    @Test func aValueOutsideItsEnumerationIsReported() throws {
        let job = patched(try goodJob(), replacing: ubyteAttribute(0, .orientation), with: ubyteAttribute(9, .orientation))
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-value"))
    }

    @Test func theSecondNameForJISB5IsReported() throws {
        // Code 13 is a second spelling of JIS B5 that not every emulation knows; 11 is the one to send.
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .orientation),
            with: ubyteAttribute(0, .orientation) + ubyteAttribute(13, .mediaSize))
        let findings = PCLXLValidator.check(job: job)
        #expect(rules(findings).contains("attribute-value") || rules(findings).contains("media-size"))
    }

    @Test func bothMediaSizeAndCustomMediaSizeIsReported() throws {
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .orientation),
            with: ubyteAttribute(0, .orientation) + ubyteAttribute(0, .mediaSize))
        #expect(rules(PCLXLValidator.check(job: job)).contains("media-size"))
    }

    @Test func duplexPageSideWithoutDuplexPageModeIsReported() throws {
        let job = patched(
            try goodJob(), replacing: ubyteAttribute(0, .simplexPageMode), with: ubyteAttribute(0, .duplexPageSide))
        #expect(rules(PCLXLValidator.check(job: job)).contains("duplex"))
    }
}

// MARK: - Structure

@Suite struct PCLXLValidatorStructureTests {
    @Test func aStreamThatNeverClosesItsSessionIsReported() throws {
        // What a cancelled job looks like: the UEL alone, with no EndSession before it.
        var sink = ByteBuffer()
        var backend = PCLXLBackend(options: JobOptions())
        let geometry = PageGeometry(width: 64, height: 8, dpi: 600, format: .gray8)
        let row = [UInt8](repeating: 0, count: geometry.bytesPerRow)
        try backend.beginJob(to: &sink)
        try backend.beginPage(geometry, to: &sink)
        try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        try backend.endJob(to: &sink)

        let findings = PCLXLValidator.check(job: sink.bytes)
        #expect(rules(findings).contains("session"))
        #expect(rules(findings).contains("page"))
    }

    @Test func anOperatorAfterEndSessionIsReported() throws {
        let job = patched(
            try goodJob(), replacing: [PCLXLOperator.endSession.rawValue],
            with: [PCLXLOperator.endSession.rawValue, PCLXLOperator.endPage.rawValue])
        #expect(rules(PCLXLValidator.check(job: job)).contains("session"))
    }

    @Test func anOperatorThisDriverDoesNotEmitIsReported() throws {
        // 0x77 is SetPenWidth: valid PCL XL, but nothing a raster driver should be sending.
        let job = patched(try goodJob(), replacing: [PCLXLOperator.endImage.rawValue], with: [0x77, PCLXLOperator.endImage.rawValue])
        #expect(rules(PCLXLValidator.check(job: job)).contains("operator"))
    }

    @Test func imageRowsThatDoNotAddUpAreReported() throws {
        let job = try goodJob(height: 200)
        let stream = try PCLXLReader.parse(job)
        let readImage = try #require(stream.operators.first { $0.tag == PCLXLOperator.readImage.rawValue })
        let blockHeight = try #require(readImage[.blockHeight]?.intValue)

        // Claim one row fewer than the block carries: the image now ends short of its SourceHeight.
        let original: [UInt8] = [
            PCLXLDataTag.uint16.rawValue, UInt8(blockHeight & 0xFF), UInt8(blockHeight >> 8),
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.blockHeight.rawValue,
        ]
        let shortened: [UInt8] = [
            PCLXLDataTag.uint16.rawValue, UInt8((blockHeight - 1) & 0xFF), UInt8((blockHeight - 1) >> 8),
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.blockHeight.rawValue,
        ]
        #expect(rules(PCLXLValidator.check(job: patched(job, replacing: original, with: shortened))).contains("image-rows"))
    }

    @Test func aDeltaRowBlockInAClass20StreamIsReported() throws {
        var options = JobOptions()
        options.compression = .deltaRow
        // The job is DeltaRow throughout; only the declared class is turned back to 2.0.
        let job = patched(
            try goodJob(options: options), replacing: Array(") HP-PCL XL;2;1;".utf8),
            with: Array(") HP-PCL XL;2;0;".utf8))
        #expect(rules(PCLXLValidator.check(job: job)).contains("compress-mode-class"))
    }

    @Test func anImageThatFallsOffTheSheetIsReported() throws {
        // A Letter sheet with the raster placed 2 inches too far right: the classic margin bug.
        let geometry = PageGeometry(
            width: 4900, height: 6400, dpi: 600, format: .gray8,
            mediaPoints: .init(width: 612, height: 792), origin: .init(x: 1300, y: 100))
        var sink = ByteBuffer()
        var backend = PCLXLBackend(options: JobOptions())
        var row = [UInt8](repeating: 0xFF, count: geometry.bytesPerRow)
        row[geometry.bytesPerRow - 1] = 0
        try backend.beginJob(to: &sink)
        try backend.beginPage(geometry, to: &sink)
        for _ in 0..<geometry.height {
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        try backend.endPage(to: &sink)
        try backend.endJob(to: &sink)

        #expect(rules(PCLXLValidator.check(job: sink.bytes)).contains("image-off-sheet"))
    }

    @Test func somethingThatIsNotPCLXLIsReportedRatherThanCrashing() {
        // Both of these fail to parse and have no UEL to end on; neither may crash the validator.
        for input in [Array("not a print job at all".utf8), []] {
            let findings = PCLXLValidator.check(job: input)
            #expect(rules(findings).contains("parse"))
            #expect(findings.hasErrors)
        }
    }
}

// MARK: - Findings from the first external review of this file

/// A minimal one-page job with one uncompressed image, built by hand because the driver never
/// sends uncompressed data and these rules are about jobs it did not write.
private func handBuiltJob(
    padBytesMultiple: Int? = nil, imageWidth: Int = 6, imageHeight: Int = 2,
    colorDepth: PCLXLColorDepth = .bits8, orientation: PCLXLOrientation = .portrait,
    cursor: (x: Int, y: Int) = (x: 0, y: 0), pageOrigin: (x: Int, y: Int)? = nil,
    customMediaSize: (x: Float, y: Float)? = nil,
    dataBytes: Int? = nil, protocolClass: (major: Int, minor: Int) = (major: 2, minor: 0),
    compressMode: PCLXLCompressMode = .none, payload: [UInt8]? = nil,
    beforeSession: [UInt8] = [], afterSession: [UInt8] = [], insidePage: [UInt8] = [],
    beforeImage: ((inout PCLXLWriter) -> Void)? = nil,
    insideImage: ((inout PCLXLWriter) -> Void)? = nil
) -> [UInt8] {
    var writer = PCLXLWriter()
    var job = PCLXLReader.uel
    job += Array("@PJL \n@PJL ENTER LANGUAGE=PCLXL\n".utf8)

    writer.streamHeader(protocolClass: protocolClass, comment: "hand built")
    writer.uint16XY(600, 600, .unitsPerMeasure)
    writer.enumeration(PCLXLMeasure.inch, .measure)
    if !beforeSession.isEmpty {
        job += writer.take()
        job += beforeSession
    }
    writer.op(.beginSession)
    writer.enumeration(PCLXLDataSource.default, .sourceType)
    writer.enumeration(PCLXLDataOrg.binaryLowByteFirst, .dataOrg)
    writer.op(.openDataSource)
    writer.enumeration(orientation, .orientation)
    if let customMediaSize {
        writer.real32XY(customMediaSize.x, customMediaSize.y, .customMediaSize)
        writer.ubyte(0, .customMediaSizeUnits)
    } else {
        writer.enumeration(PCLXLMediaSize.letter, .mediaSize)
    }
    writer.enumeration(PCLXLSimplexPageMode.frontSide, .simplexPageMode)
    writer.op(.beginPage)
    if let pageOrigin {
        writer.uint16XY(pageOrigin.x, pageOrigin.y, .pageOrigin)
        writer.op(.setPageOrigin)
    }
    beforeImage?(&writer)
    if !insidePage.isEmpty {
        job += writer.take()
        job += insidePage
    }
    writer.enumeration(PCLXLColorSpace.gray, .colorSpace)
    writer.op(.setColorSpace)
    writer.uint16XY(cursor.x, cursor.y, .point)
    writer.op(.setCursor)
    writer.enumeration(PCLXLColorMapping.directPixel, .colorMapping)
    writer.enumeration(colorDepth, .colorDepth)
    writer.uint16(imageWidth, .sourceWidth)
    writer.uint16(imageHeight, .sourceHeight)
    writer.uint16XY(imageWidth, imageHeight, .destinationSize)
    writer.op(.beginImage)
    insideImage?(&writer)

    let multiple = padBytesMultiple ?? 4
    let bits = colorDepth == .bits8 ? 8 : colorDepth == .bits4 ? 4 : 1
    let packed = (imageWidth * bits + 7) / 8
    let padded = (packed + multiple - 1) / multiple * multiple
    let data = payload?.count ?? dataBytes ?? padded * imageHeight
    writer.uint16(0, .startLine)
    writer.uint16(imageHeight, .blockHeight)
    writer.enumeration(compressMode, .compressMode)
    if let padBytesMultiple {
        writer.ubyte(UInt8(padBytesMultiple), .padBytesMultiple)
    }
    writer.op(.readImage)
    writer.dataLength(data)
    job += writer.take()
    job += payload ?? [UInt8](repeating: 0x80, count: data)

    writer.op(.endImage)
    writer.uint16(1, .pageCopies)
    writer.op(.endPage)
    writer.op(.closeDataSource)
    writer.op(.endSession)
    job += writer.take()
    job += afterSession
    return job + PCLXLReader.uel
}

@Suite struct PCLXLValidatorReviewTests {
    @Test func theHandBuiltJobIsItselfClean() {
        let findings = PCLXLValidator.check(job: handBuiltJob())
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func aPageOperatorInsideAnImageIsReported() {
        // Only image data may come between BeginImage and EndImage; an encoder that moves the
        // cursor there is rejected by the interpreter, not by any amount of pixel comparison.
        let job = handBuiltJob(insideImage: { writer in
            writer.uint16XY(10, 10, .point)
            writer.op(.setCursor)
        })
        #expect(rules(PCLXLValidator.check(job: job)).contains("image"))
    }

    @Test(arguments: [1, 2, 3, 4]) func padBytesMultipleDecidesTheStride(multiple: Int) {
        // 6 pixels of 8-bit gray: 6 bytes padded to 6, 6, 6 and 8 for multiples of 1, 2, 3 and 4.
        let findings = PCLXLValidator.check(job: handBuiltJob(padBytesMultiple: multiple))
        #expect(findings.isEmpty, "\(findings)")

        // The same block one byte short is wrong whatever the multiple is.
        let padded = (6 + multiple - 1) / multiple * multiple
        let short = handBuiltJob(padBytesMultiple: multiple, dataBytes: padded * 2 - 1)
        #expect(rules(PCLXLValidator.check(job: short)).contains("image-data-length"))
    }

    @Test func aRealAttributeThatNoIntegerCanHoldIsReportedRatherThanTrapping() throws {
        // real32 is legal for UnitsPerMeasure, and a captured job may hold anything in it.
        var job = try goodJob()
        let unitsPerMeasure: [UInt8] = [
            PCLXLDataTag.uint16XY.rawValue, 0x58, 0x02, 0x58, 0x02,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue,
        ]
        let notANumber = Float.nan.bitPattern.littleEndianBytes
        job = patched(
            job, replacing: unitsPerMeasure,
            with: [PCLXLDataTag.real32XY.rawValue] + notANumber + notANumber
                + [PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue])
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-value"))
    }

    @Test func anAttributeWithNoOperatorIsReported() throws {
        // The reader used to drop these silently, which let a malformed stream look clean.
        var job = try goodJob()
        let end = try #require(job.firstRange(of: [PCLXLOperator.endSession.rawValue]))
        job.insert(
            contentsOf: ubyteAttribute(0, .orientation), at: end.upperBound)
        #expect(rules(PCLXLValidator.check(job: job)).contains("parse"))
    }

    @Test func aSessionMeasuredInMillimetresIsNotMistakenForOneMeasuredInInches() throws {
        // UnitsPerMeasure counts units per Measure. Read as units per inch, a millimetre session
        // makes the sheet look 25.4 times too small and every image falls off it.
        let geometry = PageGeometry(
            width: 300, height: 200, dpi: 600, format: .gray8, mediaPoints: .init(width: 612, height: 792))
        var sink = ByteBuffer()
        var backend = PCLXLBackend(options: JobOptions())
        var row = [UInt8](repeating: 0xFF, count: geometry.bytesPerRow)
        row[0] = 0
        try backend.beginJob(to: &sink)
        try backend.beginPage(geometry, to: &sink)
        for _ in 0..<geometry.height {
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        try backend.endPage(to: &sink)
        try backend.endJob(to: &sink)

        let inInches: [UInt8] = [
            PCLXLDataTag.uint16XY.rawValue, 0x58, 0x02, 0x58, 0x02,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue,
            PCLXLDataTag.ubyte.rawValue, PCLXLMeasure.inch.rawValue,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.measure.rawValue,
        ]
        // 24 units per millimetre is 609.6 per inch: near enough the same page, said differently.
        let inMillimetres: [UInt8] = [
            PCLXLDataTag.uint16XY.rawValue, 24, 0, 24, 0,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue,
            PCLXLDataTag.ubyte.rawValue, PCLXLMeasure.millimeter.rawValue,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.measure.rawValue,
        ]
        let findings = PCLXLValidator.check(job: patched(sink.bytes, replacing: inInches, with: inMillimetres))
        #expect(!rules(findings).contains("image-off-sheet"), "\(findings)")
    }

    @Test func aNegativeProtocolClassIsReported() throws {
        let job = patched(try goodJob(), replacing: ") HP-PCL XL;2;0;", with: ") HP-PCL XL;2;-1;")
        #expect(rules(PCLXLValidator.check(job: job)).contains("stream-header"))
    }

    @Test func aNamedJobThatNeverEndsIsReported() throws {
        var options = JobOptions()
        options.jobName = "review test"
        let job = try goodJob(options: options)
        #expect(PCLXLValidator.check(job: job).isEmpty)

        // The trailer is where a printer's accounting learns the job finished.
        let withoutEOJ = patched(job, replacing: "@PJL EOJ NAME=\"review test\"\n", with: "")
        #expect(rules(PCLXLValidator.check(job: withoutEOJ)).contains("pjl-eoj"))

        let renamed = patched(job, replacing: "EOJ NAME=\"review test\"", with: "EOJ NAME=\"other job\"")
        #expect(rules(PCLXLValidator.check(job: renamed)).contains("pjl-eoj"))
    }
}

extension UInt32 {
    fileprivate var littleEndianBytes: [UInt8] {
        [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: self >> UInt32($0)) }
    }
}

// MARK: - Findings from the second external review of this file

@Suite struct PCLXLValidatorSecondReviewTests {
    @Test func enteringTheLanguageTwiceIsReported() throws {
        // The first ENTER LANGUAGE leaves PJL, so the printer reads the second one as stream data.
        let job = patched(
            try goodJob(), replacing: "@PJL ENTER LANGUAGE=PCLXL\n",
            with: "@PJL ENTER LANGUAGE=PCLXL\n@PJL ENTER LANGUAGE=PCLXL\n")
        #expect(rules(PCLXLValidator.check(job: job)).contains("pjl-enter-language"))
    }

    @Test(arguments: [(depth: PCLXLColorDepth.bits1, bits: 1), (depth: .bits4, bits: 4)])
    func aSubByteColourDepthStillHasItsRowLengthChecked(depth: PCLXLColorDepth, bits: Int) {
        // Integer division used to make such a row zero bytes wide, which skipped the check
        // altogether: a 1-bit block could then carry any number of bytes at all.
        let width = 17
        let packed = (width * bits + 7) / 8
        let padded = (packed + 3) / 4 * 4

        let right = handBuiltJob(imageWidth: width, colorDepth: depth, dataBytes: padded * 2)
        let findings = PCLXLValidator.check(job: right)
        #expect(findings.isEmpty, "\(findings)")

        let wrong = handBuiltJob(imageWidth: width, colorDepth: depth, dataBytes: padded * 2 + 1)
        #expect(rules(PCLXLValidator.check(job: wrong)).contains("image-data-length"))
    }

    @Test func anOperatorThisDriverDoesNotEmitIsOnlyAWarning() throws {
        // 0x77 is SetPenWidth: legal PCL XL, so a printer would accept it. Reporting it as an
        // error would have `check` claim a legal job is rejectable.
        let job = patched(
            try goodJob(), replacing: [PCLXLOperator.endImage.rawValue],
            with: [0x77, PCLXLOperator.endImage.rawValue])
        let findings = PCLXLValidator.check(job: job)
        #expect(rules(findings).contains("operator"))
        #expect(!findings.hasErrors, "\(findings)")
    }

    @Test func aPageOriginIsCountedInTheSheetBounds() {
        // SetPageOrigin moves the origin the cursor is measured from. A small image can be pushed
        // off the sheet by the origin alone, with nothing wrong with the cursor at all.
        let onSheet = handBuiltJob(pageOrigin: (x: 10, y: 10))
        #expect(PCLXLValidator.check(job: onSheet).isEmpty)

        // Letter is 5100 × 6600 at 600 units to the inch.
        let pushedOff = handBuiltJob(pageOrigin: (x: 5099, y: 10))
        #expect(rules(PCLXLValidator.check(job: pushedOff)).contains("image-off-sheet"))
    }

    @Test func aLandscapePageIsTheSheetTurnedOnItsSide() {
        // 6000 units across is off a portrait Letter sheet and on a landscape one.
        let wide = handBuiltJob(imageWidth: 600, cursor: (x: 5400, y: 10))
        #expect(rules(PCLXLValidator.check(job: wide)).contains("image-off-sheet"))

        let landscape = handBuiltJob(imageWidth: 600, orientation: .landscape, cursor: (x: 5400, y: 10))
        let findings = PCLXLValidator.check(job: landscape)
        #expect(!rules(findings).contains("image-off-sheet"), "\(findings)")
    }

    @Test func popGSWithNothingPushedIsReported() {
        let underflow = handBuiltJob(beforeImage: { writer in writer.op(.popGS) })
        #expect(rules(PCLXLValidator.check(job: underflow)).contains("graphics-state"))

        // A balanced pair is fine, and restores the cursor and colour space that were saved.
        let balanced = handBuiltJob(beforeImage: { writer in
            writer.op(.pushGS)
            writer.op(.popGS)
        })
        let findings = PCLXLValidator.check(job: balanced)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func aSessionMeasuredInRealsIsReadRatherThanTakenAsZero() throws {
        // real32XY is legal for UnitsPerMeasure. Reading only the integer shapes made it (0, 0),
        // which made the sheet zero units across and every image on it off-sheet.
        let inIntegers: [UInt8] = [
            PCLXLDataTag.uint16XY.rawValue, 0x58, 0x02, 0x58, 0x02,
            PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue,
        ]
        let sixHundred = Float(600).bitPattern.littleEndianBytes
        let inReals: [UInt8] = [PCLXLDataTag.real32XY.rawValue] + sixHundred + sixHundred
            + [PCLXLStructureTag.attributeUByte, PCLXLAttribute.unitsPerMeasure.rawValue]

        let findings = PCLXLValidator.check(job: patched(try goodJob(), replacing: inIntegers, with: inReals))
        #expect(findings.isEmpty, "\(findings)")
    }
}

// MARK: - Findings from the third external review of this file

@Suite struct PCLXLValidatorThirdReviewTests {
    @Test func aNegativeProtocolClassIsAnErrorRatherThanAWarning() throws {
        // There is no such version, so a printer rejects the stream — unlike a positive class this
        // driver merely does not emit, which is legal PCL XL.
        let negative = patched(try goodJob(), replacing: ") HP-PCL XL;2;0;", with: ") HP-PCL XL;2;-1;")
        let findings = PCLXLValidator.check(job: negative)
        #expect(findings.contains { $0.rule == "stream-header" && $0.severity == .error })

        let unsupported = patched(try goodJob(), replacing: ") HP-PCL XL;2;0;", with: ") HP-PCL XL;3;0;")
        let softer = PCLXLValidator.check(job: unsupported)
        #expect(softer.contains { $0.rule == "stream-header" && $0.severity == .warning })
        #expect(!softer.hasErrors, "\(softer)")
    }

    @Test func twoUnreadableJobNamesAreNotAMatchingPair() throws {
        // Both names fail to parse, so both read as nil. Comparing them first would let a job whose
        // PJL is malformed at both ends pass as well-formed.
        var options = JobOptions()
        options.jobName = "third review"
        var job = try goodJob(options: options)
        job = patched(job, replacing: "@PJL JOB NAME=\"third review\"", with: "@PJL JOB NAME=third review   ")
        job = patched(job, replacing: "@PJL EOJ NAME=\"third review\"", with: "@PJL EOJ NAME=other job      ")
        #expect(rules(PCLXLValidator.check(job: job)).contains("pjl-eoj"))
    }
}

// MARK: - Findings from the fourth external review of this file

@Suite struct PCLXLValidatorFourthReviewTests {
    @Test func bytesAfterTheEndOfTheJobAreReported() throws {
        // A second job concatenated onto the first, or a corrupted tail: the printer reads it
        // either way, and the job still ends in a UEL, so the framing check alone is content.
        let job = try goodJob() + Array("rubbish".utf8) + PCLXLReader.uel
        #expect(rules(PCLXLValidator.check(job: job)).contains("parse"))
    }

    @Test func aUELWithNoPJLAfterItIsReported() throws {
        // The UEL puts the printer into PJL and nothing takes it back out, so what follows is
        // read as PJL commands rather than as a PCL XL stream.
        // Everything between the opening UEL and the stream header goes, leaving the UEL alone.
        var job = try goodJob()
        let streamHeader = try #require(job.firstRange(of: Array(") HP-PCL XL".utf8)))
        job.replaceSubrange(PCLXLReader.uel.count..<streamHeader.lowerBound, with: [])
        #expect(rules(PCLXLValidator.check(job: job)).contains("pjl-enter-language"))
    }

    @Test func aFractionalSheetIsNotRoundedIntoAcceptingAnOverrun() {
        // `CustomMediaSize` is the geometry input HP documents as taking real32XY, so it is where
        // a legally encoded fractional sheet comes from. Cursor and destination are integers by
        // schema, which is why the earlier version of this test — a real32XY cursor and
        // destination — was arithmetic exercised through an encoding no printer reads.
        //
        // CustomMediaSize is given in its own measure — inches here — so at 600 units to the inch
        // 8.49983 in is a sheet 5099.898 units across. An image 5100 units wide overruns it by a
        // tenth of a unit, and rounding the sheet up to 5100 first would accept it.
        let over = handBuiltJob(imageWidth: 5100, customMediaSize: (x: 8.49983, y: 11))
        let overFindings = PCLXLValidator.check(job: over)
        #expect(rules(overFindings).contains("image-off-sheet"), "\(overFindings)")

        // The control: the same image on a sheet that really is 5100 units wide fits exactly.
        let fits = handBuiltJob(imageWidth: 5100, customMediaSize: (x: 8.5, y: 11))
        let findings = PCLXLValidator.check(job: fits)
        #expect(!rules(findings).contains("image-off-sheet"), "\(findings)")
    }
}

// MARK: - Findings from the fifth external review of this file

@Suite struct PCLXLValidatorFifthReviewTests {
    /// 0x5B is inside the operator range and is not one this driver models, so the validator meets
    /// it through the unknown-operator path.
    private static let unknownOperator: UInt8 = 0x5B

    @Test func anUnknownOperatorAfterEndSessionIsStillOutsideTheSession() {
        let job = handBuiltJob(afterSession: [Self.unknownOperator])
        let findings = PCLXLValidator.check(job: job)
        #expect(rules(findings).contains("operator"))
        #expect(errors(findings).contains { $0.rule == "session" }, "\(findings)")
    }

    @Test func anUnknownOperatorBeforeBeginSessionIsStillOutsideTheSession() {
        let job = handBuiltJob(beforeSession: [Self.unknownOperator])
        let findings = PCLXLValidator.check(job: job)
        #expect(errors(findings).contains { $0.rule == "session" }, "\(findings)")
    }

    @Test func eB5PaperIsAcceptedOnlyByTheClassThatDefinesIt() {
        // 13 is a class 2.1 addition. Treating it as legal everywhere accepts a value a 2.0
        // interpreter has never heard of; treating it as invalid everywhere rejects a legal 2.1
        // job. Both were wrong in earlier rounds, in that order.
        func withEB5(protocolClass: (major: Int, minor: Int)) -> [UInt8] {
            patched(
                handBuiltJob(protocolClass: protocolClass),
                replacing: ubyteAttribute(PCLXLMediaSize.letter.rawValue, .mediaSize),
                with: ubyteAttribute(13, .mediaSize))
        }

        // 2.0: not a value of this attribute.
        let old = PCLXLValidator.check(job: withEB5(protocolClass: (2, 0)))
        #expect(rules(old).contains("attribute-value"))

        // 2.1: legal, and only worth saying that this driver spells JIS B5 as 11.
        let new = PCLXLValidator.check(job: withEB5(protocolClass: (2, 1)))
        #expect(rules(new).contains("media-size"))
        #expect(errors(new).isEmpty, "\(new)")
    }

    @Test func twoDuplexPagesOnTheSameSideAreReported() throws {
        var options = JobOptions()
        options.duplex = .longEdge
        // The encoder alternates, so the second page's side is the only `back` in the job.
        let job = patched(
            try goodJob(pages: 2, options: options),
            replacing: ubyteAttribute(PCLXLDuplexPageSide.back.rawValue, .duplexPageSide),
            with: ubyteAttribute(PCLXLDuplexPageSide.front.rawValue, .duplexPageSide))
        #expect(rules(PCLXLValidator.check(job: job)).contains("duplex"))
    }

    @Test func anEmptyCompressedBlockDoesNotSatisfyItsDeclaredHeight() {
        // The row accounting is all declarations: StartLine, BlockHeight and SourceHeight agree
        // with each other whatever the block holds, so only decoding it shows the rows are absent.
        let rle = handBuiltJob(compressMode: .rle, payload: [])
        #expect(rules(PCLXLValidator.check(job: rle)).contains("image-data-length"))

        // The review's own example: two bytes that read as a 251-byte row, in a block of two.
        let delta = handBuiltJob(protocolClass: (major: 2, minor: 1), compressMode: .deltaRow, payload: [0xFB, 0x00])
        #expect(rules(PCLXLValidator.check(job: delta)).contains("image-data-length"))
    }

    @Test func aCompressedBlockShortOfItsDeclaredHeightIsReported() {
        // A literal packet of one byte: it decodes cleanly and is a row and a half short.
        let job = handBuiltJob(compressMode: .rle, payload: [0x00, 0x41])
        let findings = PCLXLValidator.check(job: job)
        #expect(rules(findings).contains("image-data-length"))
        #expect(findings.first { $0.rule == "image-data-length" }?.message.contains("holds 1 bytes of image") == true)
    }

    @Test func aWellFormedCompressedBlockPasses() {
        // The same two rows the uncompressed job carries, run through the encoder this driver uses.
        var compressed: [UInt8] = []
        let rows = [UInt8](repeating: 0x80, count: 8 * 2)
        rows.withUnsafeBytes { PCLXLRLE.encode($0, into: &compressed) }
        let job = handBuiltJob(compressMode: .rle, payload: compressed)
        let findings = PCLXLValidator.check(job: job)
        #expect(findings.isEmpty, "\(findings)")
    }
}

// MARK: - Findings from the owner's review

/// The bytes the writer emits for one attribute, so a test can name a wire encoding rather than
/// describe it. These fixtures exist because the implementation and the tests shared a wrong
/// premise about SetPageOrigin's operand, and agreeing with each other hid it.
private func attributeBytes(_ write: (inout PCLXLWriter) -> Void) -> [UInt8] {
    var writer = PCLXLWriter()
    write(&writer)
    return writer.take()
}

@Suite struct PCLXLValidatorSchemaTests {
    @Test func setPageOriginCarriesAttribute42() {
        // Literal, not `PCLXLAttribute.pageOrigin`: if the enum were wrong again, a test written
        // in terms of the enum would agree with it.
        let job = handBuiltJob(pageOrigin: (x: 10, y: 10))
        let origin = attributeBytes { $0.uint16XY(10, 10, .pageOrigin) }
        #expect(origin.last == 42)
        #expect(job.firstRange(of: origin) != nil, "the job does not carry PageOrigin as attribute 42")
        #expect(PCLXLValidator.check(job: job).isEmpty)
    }

    @Test func setPageOriginWithPointIsRejected() {
        // Point (76) is SetCursor's operand. On SetPageOrigin it is an attribute the operator does
        // not take, and the operand it does take is then missing.
        let job = patched(
            handBuiltJob(pageOrigin: (x: 10, y: 10)),
            replacing: attributeBytes { $0.uint16XY(10, 10, .pageOrigin) },
            with: attributeBytes { $0.uint16XY(10, 10, .point) })
        let rulesReported = rules(PCLXLValidator.check(job: job))
        #expect(rulesReported.contains("attribute-unknown"))
        #expect(rulesReported.contains("attribute-missing"))
    }

    @Test func aPositionIsNotSentAsAReal() {
        // Point takes ubyteXY, uint16XY or sint16XY. real32XY is an encoding no printer is
        // documented to read there, however sensible the number in it looks.
        let job = patched(
            handBuiltJob(),
            replacing: attributeBytes { $0.uint16XY(0, 0, .point) },
            with: attributeBytes { $0.real32XY(0, 0, .point) })
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-type"))
    }

    @Test func destinationSizeIsUint16XYOnly() {
        let job = patched(
            handBuiltJob(),
            replacing: attributeBytes { $0.uint16XY(6, 2, .destinationSize) },
            with: attributeBytes { $0.real32XY(6, 2, .destinationSize) })
        #expect(rules(PCLXLValidator.check(job: job)).contains("attribute-type"))
    }

    @Test func customMediaSizeMayBeReal() {
        // The one geometry attribute that is documented as taking real32XY, so it must not be
        // caught by the tightening above.
        let job = handBuiltJob(customMediaSize: (x: 8.5, y: 11))
        let findings = PCLXLValidator.check(job: job)
        #expect(findings.isEmpty, "\(findings)")
    }
}

@Suite struct PCLXLValidatorProtocolClassTests {
    @Test func jpegIsAClassTwoZeroCompression() {
        // DeltaRow is what class 2.1 added. JPEG has been there since 2.0, so a 2.0 stream using
        // it is not a version violation — whatever else this driver thinks of JPEG.
        let job = handBuiltJob(protocolClass: (2, 0), compressMode: .jpeg, payload: [0xFF, 0xD8, 0xFF, 0xD9])
        #expect(!rules(PCLXLValidator.check(job: job)).contains("compress-mode-class"))
    }

    @Test func deltaRowStillNeedsClassTwoOne() {
        let job = handBuiltJob(protocolClass: (2, 0), compressMode: .deltaRow, payload: [0x00, 0x00])
        #expect(rules(PCLXLValidator.check(job: job)).contains("compress-mode-class"))
    }

    @Test func theDefaultOrientationIsAClassTwoOneValue() {
        let job = { (major: Int, minor: Int) in
            patched(
                handBuiltJob(protocolClass: (major, minor)),
                replacing: ubyteAttribute(PCLXLOrientation.portrait.rawValue, .orientation),
                with: ubyteAttribute(4, .orientation))
        }
        #expect(rules(PCLXLValidator.check(job: job(2, 0))).contains("attribute-value"))
        #expect(!rules(PCLXLValidator.check(job: job(2, 1))).contains("attribute-value"))
    }

    @Test func classTwoOneNeedNotNameAnOrientation() {
        // 2.1 lets BeginPage omit Orientation; 2.0 does not.
        let job = { (major: Int, minor: Int) in
            patched(
                handBuiltJob(protocolClass: (major, minor)),
                replacing: ubyteAttribute(PCLXLOrientation.portrait.rawValue, .orientation), with: [])
        }
        #expect(rules(PCLXLValidator.check(job: job(2, 0))).contains("attribute-missing"))
        #expect(!rules(PCLXLValidator.check(job: job(2, 1))).contains("attribute-missing"))
    }

    @Test func anExternalTrayIsAMediaSource() {
        // 0…7 are the named sources and 8…255 are external trays, which a printer with a finisher
        // attached really does report.
        let job = handBuiltJob(beforeImage: { _ in })
        let withTray = patched(
            job, replacing: ubyteAttribute(PCLXLSimplexPageMode.frontSide.rawValue, .simplexPageMode),
            with: ubyteAttribute(200, .mediaSource) + ubyteAttribute(PCLXLSimplexPageMode.frontSide.rawValue, .simplexPageMode))
        #expect(!rules(PCLXLValidator.check(job: withTray)).contains("attribute-value"))
    }
}

@Suite struct PCLXLValidatorGeometryClaimTests {
    @Test func anOffSheetImageIsClippedNotRejected() {
        // PCL XL confines painting to the clipping region; it does not refuse the job. So this is
        // a fact about our output, not a prediction about the printer — and `check` must not exit
        // non-zero on a capture from a driver entitled to do it.
        let pushedOff = handBuiltJob(pageOrigin: (x: 5099, y: 10))
        let findings = PCLXLValidator.check(job: pushedOff)
        let offSheet = try? #require(findings.first { $0.rule == "image-off-sheet" })
        #expect(offSheet?.severity == .warning)
        #expect(offSheet?.category == .policy)
        #expect(!findings.hasErrors, "\(findings)")
        // It is still fatal for a job this driver wrote, which is what CI checks.
        #expect(findings.hasPolicyViolations)
    }

    @Test func anUnmodelledOperatorStopsTheSheetClaims() {
        // 0x79 is not an operator this validator follows. It could be a scale or a rotation, and
        // nothing in the tag says otherwise, so continuing to do arithmetic about where the image
        // lands would be stating a conclusion about a page that no longer exists.
        let job = handBuiltJob(pageOrigin: (x: 5099, y: 10), insidePage: [0x79])
        let findings = PCLXLValidator.check(job: job)
        let offSheet = findings.filter { $0.rule == "image-off-sheet" }
        #expect(offSheet.allSatisfy { $0.category == .coverage }, "\(offSheet)")
        #expect(!offSheet.isEmpty, "the skipped check should still be reported")
    }
}

@Suite struct PCLXLValidatorBlockSizeTests {
    @Test func aHugeBlockIsMeasuredRatherThanBuilt() {
        // 65535 × 65535 is inside every range the schema allows, and at 8 bits a pixel it is a
        // 4 GiB image. The payload is 131070 bytes: two per row, each row saying "unchanged".
        // Asking a decoder how big that is means allocating it, which is how a validator becomes
        // the thing that brings the machine down. This must answer from the encoding alone.
        let rows = 65535
        let payload = [UInt8](repeating: 0, count: rows * 2)
        let job = handBuiltJob(
            imageWidth: 65535, imageHeight: rows, protocolClass: (2, 1), compressMode: .deltaRow,
            payload: payload)
        let findings = PCLXLValidator.check(job: job)
        // Every row is present — "unchanged from the seed" is a row — so there is nothing wrong
        // with its length. The point of the test is that we got here at all.
        #expect(!rules(findings).contains("image-data-length"), "\(findings.prefix(4))")
    }

    @Test func aTruncatedHugeBlockIsReportedWithoutBuildingIt() {
        // The same declared geometry, with the rows cut short: reported, still without allocating.
        let job = handBuiltJob(
            imageWidth: 65535, imageHeight: 65535, protocolClass: (2, 1), compressMode: .deltaRow,
            payload: [0x00, 0x00, 0x00, 0x00])
        #expect(rules(PCLXLValidator.check(job: job)).contains("image-data-length"))
    }

    @Test func anRLEBlockThatDecodesLongIsAccepted() {
        // Recorded deliberately rather than left to fall out of a comparison: nothing here
        // establishes that a printer refuses a block decoding to more than its rows need, only
        // that one decoding to less cannot fill them. If evidence turns up, this test is where
        // the decision changes.
        var payload: [UInt8] = []
        let rows = [UInt8](repeating: 0x80, count: 8 * 2 + 16)
        rows.withUnsafeBytes { PCLXLRLE.encode($0, into: &payload) }
        let job = handBuiltJob(compressMode: .rle, payload: payload)
        let findings = PCLXLValidator.check(job: job)
        #expect(!rules(findings).contains("image-data-length"), "\(findings)")
    }

    @Test func aJPEGBlockIsReportedAsUnchecked() {
        // Legal in class 2.0 and not something this validator reads. Saying nothing would let it
        // pass as verified; saying "error" would claim the printer rejects a block we did not read.
        let job = handBuiltJob(compressMode: .jpeg, payload: [0xFF, 0xD8, 0xFF, 0xD9])
        let findings = PCLXLValidator.check(job: job)
        #expect(findings.contains { $0.rule == "image-data-length" && $0.category == .coverage })
        #expect(!findings.hasErrors, "\(findings)")
    }
}
