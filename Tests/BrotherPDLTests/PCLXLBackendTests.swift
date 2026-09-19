import Testing

@testable import BrotherPDL

// MARK: - Helpers

private struct TestPage {
    var geometry: PageGeometry
    var pixels: [UInt8]

    init(width: Int, height: Int, format: PixelFormat) {
        geometry = PageGeometry(width: width, height: height, dpi: 600, format: format)
        pixels = [UInt8](repeating: 0xFF, count: geometry.bytesPerRow * height)
    }

    mutating func fill(x: Range<Int>, y: Range<Int>, _ color: [UInt8]) {
        let bytesPerPixel = geometry.format == .rgb8 ? 3 : 1
        precondition(color.count == bytesPerPixel)
        for row in y {
            for column in x {
                for channel in 0..<bytesPerPixel {
                    pixels[row * geometry.bytesPerRow + column * bytesPerPixel + channel] = color[channel]
                }
            }
        }
    }

    /// Neutral noise: every pixel gets R == G == B (or one gray byte).
    mutating func neutralNoise(x: Range<Int>, y: Range<Int>, seed: UInt64) {
        var state = seed
        let bytesPerPixel = geometry.format == .rgb8 ? 3 : 1
        for row in y {
            for column in x {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = UInt8(truncatingIfNeeded: state >> 33)
                fill(x: column..<column + 1, y: row..<row + 1, [UInt8](repeating: value, count: bytesPerPixel))
            }
        }
    }

    var asRGB: [UInt8] {
        geometry.format == .rgb8 ? pixels : pixels.flatMap { [$0, $0, $0] }
    }
}

private func encode(_ pages: [TestPage], options: JobOptions = JobOptions(), abandonLastPage: Bool = false) throws -> [UInt8] {
    var sink = ByteBuffer()
    var backend = PCLXLBackend(options: options)
    try backend.beginJob(to: &sink)
    for (index, page) in pages.enumerated() {
        try backend.beginPage(page.geometry, to: &sink)
        try page.pixels.withUnsafeBytes { pixels in
            for row in 0..<page.geometry.height {
                let start = row * page.geometry.bytesPerRow
                try backend.writeRow(
                    UnsafeRawBufferPointer(rebasing: pixels[start..<start + page.geometry.bytesPerRow]), to: &sink)
            }
        }
        if !(abandonLastPage && index == pages.count - 1) {
            try backend.endPage(to: &sink)
        }
    }
    try backend.endJob(to: &sink)
    return sink.bytes
}

private func decode(_ job: [UInt8]) throws -> (stream: PCLXLStream, pages: [PCLXLDecodedPage]) {
    let stream = try PCLXLReader.parse(job)
    return (stream, try PCLXLRenderer.pages(of: stream))
}

private func operators(_ stream: PCLXLStream) -> [PCLXLOperator?] {
    stream.operators.map { PCLXLOperator(rawValue: $0.tag) }
}

/// A page with a neutral block, optional colour, and ink that is not aligned to bands or to 4-byte rows.
private func samplePage(width: Int, height: Int, colorAt colorRows: Range<Int>?) -> TestPage {
    var page = TestPage(width: width, height: height, format: .rgb8)
    page.fill(x: 3..<width - 5, y: 10..<14, [0, 0, 0])
    page.neutralNoise(x: 7..<min(width, 60), y: 120..<140, seed: 42)
    page.fill(x: width / 2..<width / 2 + 1, y: height - 1..<height, [0x40, 0x40, 0x40])
    if let colorRows {
        page.fill(x: 11..<30, y: colorRows, [0xE0, 0x10, 0x20])
    }
    return page
}

// MARK: - Framing

@Suite struct PCLXLFramingTests {
    @Test func pjlHeaderDefault() {
        let header = PJL.header(language: "PCLXL", options: JobOptions(), grayscale: false)
        let expected =
            "\u{1B}%-12345X@PJL \n@PJL SET ECONOMODE=OFF\n@PJL SET RESOLUTION=600\n"
            + "@PJL SET RENDERMODE=COLOR\n@PJL SET SOURCETRAY=AUTO\n@PJL ENTER LANGUAGE=PCLXL\n"
        #expect(header == Array(expected.utf8))
    }

    @Test func pjlHeaderWithoutBrotherVariables() {
        var options = JobOptions()
        options.brotherPJL = false
        options.jobName = "Quarterly \"report\" – final\n"
        let header = String(decoding: PJL.header(language: "PCLXL", options: options, grayscale: false), as: UTF8.self)
        #expect(header == "\u{1B}%-12345X@PJL \n@PJL JOB NAME=\"Quarterly report  final\"\n@PJL ENTER LANGUAGE=PCLXL\n")
        let trailer = String(decoding: PJL.trailer(options: options), as: UTF8.self)
        #expect(trailer == "\u{1B}%-12345X@PJL EOJ NAME=\"Quarterly report  final\"\n\u{1B}%-12345X")
    }

    @Test func tonerSaveMonoAndTray() {
        var options = JobOptions()
        options.tonerSave = true
        options.inputSlot = .tray1
        let header = String(decoding: PJL.header(language: "PCLXL", options: options, grayscale: true), as: UTF8.self)
        #expect(header.contains("@PJL SET ECONOMODE=ON\n"))
        #expect(header.contains("@PJL SET RENDERMODE=GRAYSCALE\n"))
        #expect(header.contains("@PJL SET SOURCETRAY=TRAY1\n"))
    }

    @Test func sessionBytesAreExact() throws {
        let job = try encode([])
        let pjl = PJL.header(language: "PCLXL", options: JobOptions(), grayscale: false)
        let session: [UInt8] =
            Array(") HP-PCL XL;2;0;brother-mac-driver\n".utf8)
            + [0xD1, 0x58, 0x02, 0x58, 0x02, 0xF8, 0x89]  // UnitsPerMeasure 600 600
            + [0xC0, 0x00, 0xF8, 0x86]  // Measure inch
            + [0xC0, 0x01, 0xF8, 0x8F]  // ErrorReport backChannel
            + [0x41]  // BeginSession
            + [0xC0, 0x00, 0xF8, 0x88]  // SourceType default
            + [0xC0, 0x01, 0xF8, 0x82]  // DataOrg little-endian
            + [0x48]  // OpenDataSource
            + [0x49, 0x42]  // CloseDataSource EndSession
        #expect(job == pjl + session + PJL.uel)
    }

    @Test func blankPageHasNoImages() throws {
        let (stream, pages) = try decode(try encode([TestPage(width: 64, height: 300, format: .rgb8)]))
        #expect(operators(stream) == [.beginSession, .openDataSource, .beginPage, .endPage, .closeDataSource, .endSession])
        #expect(pages.count == 1)
        #expect(pages[0].images.isEmpty)
        #expect(pages[0].endPage[.pageCopies]?.intValue == 1)
    }

    @Test func deltaRowDeclaresProtocolClass21() throws {
        var options = JobOptions()
        options.compression = .deltaRow
        #expect(try decode(try encode([], options: options)).stream.streamHeader == ") HP-PCL XL;2;1;brother-mac-driver")
    }

    @Test func errorPageOption() throws {
        var options = JobOptions()
        options.errorPage = true
        let session = try #require(try decode(try encode([], options: options)).stream.operators.first)
        #expect(session[.errorReport]?.intValue == Int(PCLXLErrorReport.errorPage.rawValue))
    }

    @Test func cancelledMidPageEndsWithBareUEL() throws {
        let job = try encode([samplePage(width: 64, height: 300, colorAt: 5..<9)], abandonLastPage: true)
        #expect(job.suffix(PJL.uel.count) == PJL.uel[...])
        let ops = operators(try PCLXLReader.parse(job))
        #expect(!ops.contains(.endPage))
        #expect(!ops.contains(.endSession))
        // Every image that was started was also finished.
        #expect(ops.filter { $0 == .beginImage }.count == ops.filter { $0 == .endImage }.count)
    }
}

// MARK: - Page setup

@Suite struct PCLXLPageSetupTests {
    private func beginPages(_ pages: [TestPage], _ options: JobOptions = JobOptions()) throws -> [PCLXLOperatorRecord] {
        try decode(try encode(pages, options: options)).pages.map(\.beginPage)
    }

    @Test(arguments: [
        (5100, 6600, PCLXLMediaSize.letter), (4958, 7017, .a4), (5100, 8400, .legal), (2600, 5200, .dlEnvelope),
    ])
    func standardMedia(width: Int, height: Int, expected: PCLXLMediaSize) throws {
        let begin = try beginPages([TestPage(width: width, height: height, format: .gray8)])[0]
        #expect(begin[.mediaSize]?.intValue == Int(expected.rawValue))
        #expect(begin[.customMediaSize] == nil)
        #expect(begin[.orientation]?.intValue == 0)
    }

    @Test func customMediaInTenthsOfMillimetre() throws {
        // 3 × 5 in has no PCL XL code: 76.2 × 127 mm.
        let begin = try beginPages([TestPage(width: 1800, height: 3000, format: .gray8)])[0]
        #expect(begin[.mediaSize] == nil)
        #expect(begin[.customMediaSize]?.intArray == [762, 1270])
        #expect(begin[.customMediaSizeUnits]?.intValue == Int(PCLXLMeasure.tenthsOfAMillimeter.rawValue))
    }

    /// What the macOS rasteriser really delivers for US Letter: only the imageable area
    /// (612 × 792 pt sheet, 12 pt margins → 4900 × 6400 px at 600 dpi).
    private func imageableLetterPage() -> TestPage {
        var page = TestPage(width: 4900, height: 6400, format: .gray8)
        page.geometry.mediaPoints = .init(width: 612, height: 792)
        page.geometry.origin = .init(x: 100, y: 100)
        return page
    }

    @Test func mediaComesFromTheSheetNotTheRaster() throws {
        let begin = try beginPages([imageableLetterPage()])[0]
        #expect(begin[.mediaSize]?.intValue == Int(PCLXLMediaSize.letter.rawValue))
        #expect(begin[.customMediaSize] == nil)
    }

    @Test func customMediaComesFromTheSheetNotTheRaster() throws {
        // 3 × 5 in sheet (216 × 360 pt) with 12 pt margins → 1600 × 2800 px raster.
        var page = TestPage(width: 1600, height: 2800, format: .gray8)
        page.geometry.mediaPoints = .init(width: 216, height: 360)
        page.geometry.origin = .init(x: 100, y: 100)
        #expect(try beginPages([page])[0][.customMediaSize]?.intArray == [762, 1270])
    }

    @Test func imagesAreShiftedByTheRasterOrigin() throws {
        var page = imageableLetterPage()
        page.fill(x: 0..<2, y: 0..<1, [0])
        page.fill(x: 4899..<4900, y: 6399..<6400, [0])
        let images = try decode(try encode([page])).pages[0].images
        #expect(images.map { [$0.x, $0.y, $0.width, $0.height] } == [[100, 100, 2, 1], [4999, 6499, 1, 1]])
    }

    /// The sheet is declared exactly as the raster is laid out. A sheet that only matches a known
    /// size when turned must not be declared as that size: the page is always sent as portrait, so
    /// the printer would take the sheet to be narrower than the raster and clip it.
    @Test(arguments: [
        // Long-edge DL envelope, the rotation of the DL envelope that precedes it in the table.
        (624.0, 312.0, 5000, 2400, [2201, 1101]),
        // US Letter turned on its side.
        (792.0, 612.0, 6400, 4900, [2794, 2159]),
    ])
    func sidewaysSheetIsNeverDeclaredAsItsUprightSize(
        sheetWidth: Double, sheetHeight: Double, width: Int, height: Int, tenthsOfMillimetre: [Int]
    ) throws {
        var page = TestPage(width: width, height: height, format: .gray8)
        page.geometry.mediaPoints = .init(width: sheetWidth, height: sheetHeight)
        page.geometry.origin = .init(x: 100, y: 100)
        let begin = try beginPages([page])[0]
        #expect(begin[.mediaSize] == nil)
        #expect(begin[.customMediaSize]?.intArray == tenthsOfMillimetre)
    }

    @Test func explicitMediaWins() throws {
        var options = JobOptions()
        options.media = MediaSize.named("A5")
        let begin = try beginPages([TestPage(width: 5100, height: 6600, format: .gray8)], options)[0]
        #expect(begin[.mediaSize]?.intValue == Int(PCLXLMediaSize.a5.rawValue))
    }

    @Test func simplex() throws {
        let begin = try beginPages([TestPage(width: 64, height: 10, format: .gray8)])[0]
        #expect(begin[.simplexPageMode]?.intValue == 0)
        #expect(begin[.duplexPageMode] == nil)
        #expect(begin[.duplexPageSide] == nil)
    }

    @Test(arguments: [(JobOptions.Duplex.longEdge, 1), (.shortEdge, 0)])
    func duplexAlternatesSides(duplex: JobOptions.Duplex, mode: Int) throws {
        var options = JobOptions()
        options.duplex = duplex
        let begins = try beginPages([TestPage](repeating: TestPage(width: 64, height: 10, format: .gray8), count: 3), options)
        #expect(begins.map { $0[.duplexPageMode]?.intValue } == [mode, mode, mode])
        #expect(begins.map { $0[.duplexPageSide]?.intValue } == [0, 1, 0])
        #expect(begins.allSatisfy { $0[.simplexPageMode] == nil })
    }

    @Test(arguments: [
        (JobOptions.InputSlot.auto, PCLXLMediaSource.autoSelect), (.tray1, .upperCassette),
        (.tray2, .lowerCassette), (.manual, .manualFeed),
    ])
    func mediaSource(slot: JobOptions.InputSlot, expected: PCLXLMediaSource) throws {
        var options = JobOptions()
        options.inputSlot = slot
        let begin = try beginPages([TestPage(width: 64, height: 10, format: .gray8)], options)[0]
        #expect(begin[.mediaSource]?.intValue == Int(expected.rawValue))
    }

    @Test func rejectsOneBitAndWrongResolution() throws {
        var sink = ByteBuffer()
        var backend = PCLXLBackend(options: JobOptions())
        try backend.beginJob(to: &sink)
        #expect(throws: PCLXLError.self) {
            try backend.beginPage(PageGeometry(width: 8, height: 8, dpi: 600, format: .black1), to: &sink)
        }
        #expect(throws: PCLXLError.self) {
            try backend.beginPage(PageGeometry(width: 8, height: 8, dpi: 300, format: .rgb8), to: &sink)
        }
    }
}

// MARK: - Raster

@Suite struct PCLXLRasterTests {
    static let compressions: [JobOptions.Compression] = [.rle, .deltaRow]
    /// Widths chosen so RGB and gray rows both hit every 4-byte padding remainder.
    static let widths = [61, 62, 63, 64, 129]

    @Test(arguments: compressions, widths)
    func colourPageRoundTrips(compression: JobOptions.Compression, width: Int) throws {
        var options = JobOptions()
        options.compression = compression
        let page = samplePage(width: width, height: 300, colorAt: 40..<45)
        let decoded = try decode(try encode([page], options: options)).pages
        #expect(try decoded[0].composite(width: width, height: 300, format: .rgb8) == page.pixels)
        #expect(decoded[0].images.allSatisfy { $0.format == .rgb8 })
    }

    @Test(arguments: compressions, widths)
    func neutralPageRoundTripsAsGray(compression: JobOptions.Compression, width: Int) throws {
        var options = JobOptions()
        options.compression = compression
        let page = samplePage(width: width, height: 300, colorAt: nil)
        let decoded = try decode(try encode([page], options: options)).pages
        #expect(try decoded[0].composite(width: width, height: 300, format: .rgb8) == page.pixels)
        #expect(!decoded[0].images.isEmpty)
        #expect(decoded[0].images.allSatisfy { $0.format == .gray8 })
    }

    /// Colour first appears after whole bands have been held as gray, and part-way into a band:
    /// held bands and the partial band must both be replayed as RGB, leaving no gray image on the page.
    @Test(arguments: compressions, [0..<1, 127..<128, 128..<129, 200..<203, 299..<300])
    func lateColourReplaysHeldBands(compression: JobOptions.Compression, colorRows: Range<Int>) throws {
        var options = JobOptions()
        options.compression = compression
        let page = samplePage(width: 63, height: 300, colorAt: colorRows)
        let (stream, decoded) = try decode(try encode([page], options: options))
        #expect(try decoded[0].composite(width: 63, height: 300, format: .rgb8) == page.pixels)
        #expect(decoded[0].images.allSatisfy { $0.format == .rgb8 })
        let spaces = stream.operators.filter { $0.tag == PCLXLOperator.setColorSpace.rawValue }
        #expect(spaces.map { $0[.colorSpace]?.intValue } == [Int(PCLXLColorSpace.rgb.rawValue)])
    }

    @Test func colourDecisionIsPerPage() throws {
        let pages = [
            samplePage(width: 64, height: 200, colorAt: nil),
            samplePage(width: 64, height: 200, colorAt: 150..<151),
            samplePage(width: 64, height: 200, colorAt: nil),
        ]
        let decoded = try decode(try encode(pages)).pages
        #expect(decoded.map { Set($0.images.map(\.format)) } == [[.gray8], [.rgb8], [.gray8]])
        for (page, result) in zip(pages, decoded) {
            #expect(try result.composite(width: 64, height: 200, format: .rgb8) == page.pixels)
        }
    }

    @Test func forcedColourNeverSendsGray() throws {
        var options = JobOptions()
        options.colorMode = .color
        let page = samplePage(width: 64, height: 200, colorAt: nil)
        let decoded = try decode(try encode([page], options: options)).pages
        #expect(decoded[0].images.allSatisfy { $0.format == .rgb8 })
        #expect(try decoded[0].composite(width: 64, height: 200, format: .rgb8) == page.pixels)
    }

    @Test func monoConvertsColourWithLuma() throws {
        var options = JobOptions()
        options.colorMode = .mono
        var page = TestPage(width: 16, height: 4, format: .rgb8)
        page.fill(x: 2..<3, y: 1..<2, [255, 0, 0])
        page.fill(x: 3..<4, y: 1..<2, [0, 255, 0])
        page.fill(x: 4..<5, y: 1..<2, [0, 0, 255])
        page.fill(x: 5..<6, y: 1..<2, [90, 90, 90])
        let (stream, decoded) = try decode(try encode([page], options: options))
        #expect(stream.pjlHeader.contains("@PJL SET RENDERMODE=GRAYSCALE"))
        let image = try #require(decoded[0].images.first)
        #expect(image.format == .gray8)
        #expect((image.x, image.y, image.width, image.height) == (2, 1, 4, 1))
        // (weight × 255 + 128) >> 8 for weights 77, 150, 29; a neutral pixel is unchanged.
        #expect(image.pixels == [77, 149, 29, 90])
    }

    @Test(arguments: compressions)
    func grayInputRoundTrips(compression: JobOptions.Compression) throws {
        var options = JobOptions()
        options.compression = compression
        var page = TestPage(width: 61, height: 260, format: .gray8)
        page.neutralNoise(x: 0..<61, y: 100..<140, seed: 7)
        page.fill(x: 60..<61, y: 259..<260, [0])
        let decoded = try decode(try encode([page], options: options)).pages
        #expect(try decoded[0].composite(width: 61, height: 260, format: .gray8) == page.pixels)
    }

    @Test func imagesAreCroppedToInkAndBlankBandsSkipped() throws {
        var page = TestPage(width: 400, height: 1000, format: .rgb8)
        page.fill(x: 100..<110, y: 300..<303, [0, 0, 0])
        page.fill(x: 50..<51, y: 900..<901, [1, 2, 3])
        let images = try decode(try encode([page])).pages[0].images
        #expect(images.map { [$0.x, $0.y, $0.width, $0.height] } == [[100, 300, 10, 3], [50, 900, 1, 1]])
    }

    @Test func inkSpanningBandsBecomesAdjacentImages() throws {
        var page = TestPage(width: 40, height: 400, format: .gray8)
        page.fill(x: 5..<9, y: 120..<260, [0x80])
        let images = try decode(try encode([page])).pages[0].images
        #expect(images.map { [$0.x, $0.y, $0.width, $0.height] } == [[5, 120, 4, 8], [5, 128, 4, 128], [5, 256, 4, 4]])
    }
}

// MARK: - Row analysis

@Suite struct RowAnalysisTests {
    @Test(arguments: [0, 1, 7, 8, 9, 16, 23, 64, 100])
    func inkExtentOfBlankRowIsNil(count: Int) {
        [UInt8](repeating: 0xFF, count: count).withUnsafeBytes {
            #expect(PCLXLBackend.inkExtent($0) == nil)
        }
    }

    @Test func inkExtentFindsBothEnds() {
        for count in [1, 7, 8, 9, 15, 16, 17, 40] {
            for low in 0..<count {
                for high in low..<count {
                    var row = [UInt8](repeating: 0xFF, count: count)
                    row[low] = 0
                    row[high] = 0xFE
                    row.withUnsafeBytes {
                        #expect(PCLXLBackend.inkExtent($0) == low..<high + 1, "count \(count) ink \(low)...\(high)")
                    }
                }
            }
        }
    }

    @Test func neutralityLooksAtWholePixels() {
        // Ink extent starts on the blue byte of pixel 1; the pixel's red and green must still be compared.
        let row: [UInt8] = [255, 255, 255, 255, 255, 9, 7, 7, 7]
        row.withUnsafeBytes {
            #expect(PCLXLBackend.inkExtent($0) == 5..<9)
            #expect(!PCLXLBackend.isNeutral($0, inkBytes: 5..<9))
            #expect(PCLXLBackend.isNeutral($0, inkBytes: 6..<9))
        }
    }
}
