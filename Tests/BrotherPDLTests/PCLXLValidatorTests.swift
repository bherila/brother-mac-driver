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
    dataBytes: Int? = nil, beforeImage: ((inout PCLXLWriter) -> Void)? = nil,
    insideImage: ((inout PCLXLWriter) -> Void)? = nil
) -> [UInt8] {
    var writer = PCLXLWriter()
    var job = PCLXLReader.uel
    job += Array("@PJL \n@PJL ENTER LANGUAGE=PCLXL\n".utf8)

    writer.streamHeader(protocolClass: (major: 2, minor: 0), comment: "hand built")
    writer.uint16XY(600, 600, .unitsPerMeasure)
    writer.enumeration(PCLXLMeasure.inch, .measure)
    writer.op(.beginSession)
    writer.enumeration(PCLXLDataSource.default, .sourceType)
    writer.enumeration(PCLXLDataOrg.binaryLowByteFirst, .dataOrg)
    writer.op(.openDataSource)
    writer.enumeration(orientation, .orientation)
    writer.enumeration(PCLXLMediaSize.letter, .mediaSize)
    writer.enumeration(PCLXLSimplexPageMode.frontSide, .simplexPageMode)
    writer.op(.beginPage)
    if let pageOrigin {
        writer.uint16XY(pageOrigin.x, pageOrigin.y, .point)
        writer.op(.setPageOrigin)
    }
    beforeImage?(&writer)
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
    let data = dataBytes ?? padded * imageHeight
    writer.uint16(0, .startLine)
    writer.uint16(imageHeight, .blockHeight)
    writer.enumeration(PCLXLCompressMode.none, .compressMode)
    if let padBytesMultiple {
        writer.ubyte(UInt8(padBytesMultiple), .padBytesMultiple)
    }
    writer.op(.readImage)
    writer.dataLength(data)
    job += writer.take()
    job += [UInt8](repeating: 0x80, count: data)

    writer.op(.endImage)
    writer.uint16(1, .pageCopies)
    writer.op(.endPage)
    writer.op(.closeDataSource)
    writer.op(.endSession)
    job += writer.take()
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
