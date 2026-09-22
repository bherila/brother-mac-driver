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
