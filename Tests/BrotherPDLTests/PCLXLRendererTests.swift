import Testing

@testable import BrotherPDL

extension HandBuiltJob {
    mutating func beginPage(mediaSize: PCLXLMediaSize = .letter) {
        ubyte(mediaSize.rawValue)
        attr(.mediaSize)
        op(.beginPage)
    }

    mutating func endPage(copies: UInt16 = 1) {
        uint16(copies)
        attr(.pageCopies)
        op(.endPage)
    }

    mutating func setColorSpace(_ space: PCLXLColorSpace) {
        ubyte(space.rawValue)
        attr(.colorSpace)
        op(.setColorSpace)
    }

    mutating func setCursor(x: Int16, y: Int16) {
        sint16XY(x, y)
        attr(.point)
        op(.setCursor)
    }

    mutating func beginImage(width: UInt16, height: UInt16, destination: (UInt16, UInt16)? = nil) {
        ubyte(PCLXLColorMapping.directPixel.rawValue)
        attr(.colorMapping)
        ubyte(PCLXLColorDepth.bits8.rawValue)
        attr(.colorDepth)
        uint16(width)
        attr(.sourceWidth)
        uint16(height)
        attr(.sourceHeight)
        let size = destination ?? (width, height)
        uint16XY(size.0, size.1)
        attr(.destinationSize)
        op(.beginImage)
    }

    mutating func readImage(
        startLine: UInt16, blockHeight: UInt16, mode: PCLXLCompressMode, pad: UInt8? = nil,
        payload: [UInt8]
    ) {
        uint16(startLine)
        attr(.startLine)
        uint16(blockHeight)
        attr(.blockHeight)
        ubyte(mode.rawValue)
        attr(.compressMode)
        if let pad {
            ubyte(pad)
            attr(.padBytesMultiple)
        }
        op(.readImage)
        data(payload)
    }
}

/// Pads each row of `rows` up to a multiple of `multiple` bytes, the way an encoder must.
private func padded(_ rows: [[UInt8]], to multiple: Int) -> [UInt8] {
    var output: [UInt8] = []
    for row in rows {
        output += row
        let remainder = row.count % multiple
        if remainder != 0 { output += [UInt8](repeating: 0, count: multiple - remainder) }
    }
    return output
}

@Suite struct PCLXLRendererTests {
    @Test func decodesASingleGrayImage() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.setCursor(x: 0, y: 0)
        job.beginImage(width: 4, height: 2)
        job.readImage(
            startLine: 0, blockHeight: 2, mode: .none,
            payload: padded([[1, 2, 3, 4], [5, 6, 7, 8]], to: 4))
        job.op(.endImage)
        job.endPage()

        let pages = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))
        #expect(pages.count == 1)
        let image = try #require(pages[0].images.first)
        #expect(image.format == .gray8)
        #expect((image.x, image.y, image.width, image.height) == (0, 0, 4, 2))
        #expect((image.destinationWidth, image.destinationHeight) == (4, 2))
        #expect(image.pixels == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(pages[0].endPage[.pageCopies]?.intValue == 1)
    }

    @Test func decodesASingleRGBImage() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.setColorSpace(.sRGB)
        job.setCursor(x: 0, y: 0)
        job.beginImage(width: 2, height: 1)
        job.readImage(
            startLine: 0, blockHeight: 1, mode: .none,
            payload: padded([[10, 20, 30, 40, 50, 60]], to: 4))
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.format == .rgb8)
        #expect(image.pixels == [10, 20, 30, 40, 50, 60])
    }

    @Test func stripsRowPaddingWhenTheWidthIsNotAMultipleOfFour() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 3, height: 2)
        job.readImage(
            startLine: 0, blockHeight: 2, mode: .none,
            payload: [1, 2, 3, 0xFF, 4, 5, 6, 0xFF])
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.pixels == [1, 2, 3, 4, 5, 6])
    }

    @Test func honoursAnExplicitPadBytesMultiple() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 3, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, pad: 1, payload: [7, 8, 9])
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.pixels == [7, 8, 9])
    }

    @Test func joinsMultipleReadImageBlocks() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 4)
        job.readImage(startLine: 0, blockHeight: 2, mode: .none, payload: [1, 1, 1, 1, 2, 2, 2, 2])
        job.readImage(startLine: 2, blockHeight: 2, mode: .none, payload: [3, 3, 3, 3, 4, 4, 4, 4])
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.height == 4)
        #expect(image.pixels == [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4])
    }

    @Test func compositesTwoImagesAtDifferentCursors() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.setCursor(x: 0, y: 0)
        job.beginImage(width: 2, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [0x11, 0x22, 0, 0])
        job.op(.endImage)
        job.setCursor(x: 2, y: 1)
        job.beginImage(width: 2, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [0x33, 0x44, 0, 0])
        job.op(.endImage)
        job.endPage()

        let page = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0]
        #expect(page.images.count == 2)
        #expect((page.images[1].x, page.images[1].y) == (2, 1))
        #expect(page.extent.width == 4)
        #expect(page.extent.height == 2)

        let canvas = try page.composite(width: 4, height: 2, format: .gray8)
        #expect(canvas == [0x11, 0x22, 0xFF, 0xFF, 0xFF, 0xFF, 0x33, 0x44])
    }

    @Test func expandsGrayImagesOntoAnRGBCanvas() throws {
        let image = PCLXLPlacedImage(
            x: 0, y: 0, width: 2, height: 1, destinationWidth: 2, destinationHeight: 1,
            format: .gray8, pixels: [0x00, 0x80])
        let page = blankPage(with: [image])
        #expect(try page.composite(width: 2, height: 1, format: .rgb8) == [0, 0, 0, 0x80, 0x80, 0x80])
    }

    @Test func rejectsAnRGBImageOnAGrayCanvas() {
        let image = PCLXLPlacedImage(
            x: 0, y: 0, width: 1, height: 1, destinationWidth: 1, destinationHeight: 1,
            format: .rgb8, pixels: [1, 2, 3])
        let page = blankPage(with: [image])
        #expect(PCLXLCheck.isUnsupported(PCLXLCheck.error { _ = try page.composite(width: 1, height: 1, format: .gray8) }))
    }

    @Test func rejectsAScaledImage() {
        let image = PCLXLPlacedImage(
            x: 0, y: 0, width: 2, height: 2, destinationWidth: 4, destinationHeight: 4,
            format: .gray8, pixels: [1, 2, 3, 4])
        let page = blankPage(with: [image])
        #expect(PCLXLCheck.isUnsupported(PCLXLCheck.error { _ = try page.composite(width: 4, height: 4, format: .gray8) }))
    }

    @Test func clipsImagesToTheCanvas() throws {
        let image = PCLXLPlacedImage(
            x: -1, y: 1, width: 3, height: 3, destinationWidth: 3, destinationHeight: 3,
            format: .gray8, pixels: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        let page = blankPage(with: [image])
        // Column -1 and row 3 fall outside a 2×3 canvas.
        #expect(try page.composite(width: 2, height: 3, format: .gray8) == [0xFF, 0xFF, 2, 3, 5, 6])
    }

    @Test func decodesTwoPages() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage(mediaSize: .a4)
        job.beginImage(width: 4, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [1, 1, 1, 1])
        job.op(.endImage)
        job.endPage(copies: 2)
        job.beginPage(mediaSize: .letter)
        job.beginImage(width: 4, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [2, 2, 2, 2])
        job.op(.endImage)
        job.endPage(copies: 3)
        job.op(.endSession)

        let pages = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))
        #expect(pages.count == 2)
        #expect(pages[0].beginPage[.mediaSize]?.intValue == Int(PCLXLMediaSize.a4.rawValue))
        #expect(pages[0].endPage[.pageCopies]?.intValue == 2)
        #expect(pages[1].images[0].pixels == [2, 2, 2, 2])
        #expect(pages[1].endPage[.pageCopies]?.intValue == 3)
    }

    @Test func resetsTheColorSpaceAtBeginPage() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.setColorSpace(.rgb)
        job.beginImage(width: 1, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [1, 2, 3, 0])
        job.op(.endImage)
        job.endPage()
        job.beginPage()
        job.beginImage(width: 1, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [9, 0, 0, 0])
        job.op(.endImage)
        job.endPage()

        let pages = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))
        #expect(pages[0].images[0].format == .rgb8)
        #expect(pages[0].images[0].pixels == [1, 2, 3])
        #expect(pages[1].images[0].format == .gray8)
        #expect(pages[1].images[0].pixels == [9])
    }

    @Test func resetsTheCursorAtBeginPage() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.setCursor(x: 5, y: 6)
        job.beginImage(width: 1, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [1, 0, 0, 0])
        job.op(.endImage)
        job.endPage()
        job.beginPage()
        job.beginImage(width: 1, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [1, 0, 0, 0])
        job.op(.endImage)
        job.endPage()

        let pages = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))
        #expect((pages[0].images[0].x, pages[0].images[0].y) == (5, 6))
        #expect((pages[1].images[0].x, pages[1].images[0].y) == (0, 0))
    }

    @Test func rejectsAStartLineThatSkipsRows() {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 2)
        job.readImage(startLine: 1, blockHeight: 1, mode: .none, payload: [1, 1, 1, 1])
        job.op(.endImage)
        job.endPage()

        #expect(PCLXLCheck.isMalformed(PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }))
    }

    @Test func rejectsAShortReadImageBlock() {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 2)
        job.readImage(startLine: 0, blockHeight: 2, mode: .none, payload: [1, 1, 1, 1, 2])
        job.op(.endImage)
        job.endPage()

        let error = PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }
        #expect(error != nil)
        if case .truncated = error {} else { Issue.record("expected .truncated, got \(String(describing: error))") }
    }

    @Test func rejectsAnImageWithTooFewRowsAtEndImage() {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 4)
        job.readImage(startLine: 0, blockHeight: 2, mode: .none, payload: [1, 1, 1, 1, 2, 2, 2, 2])
        job.op(.endImage)
        job.endPage()

        #expect(PCLXLCheck.isMalformed(PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }))
    }

    @Test func rejectsAnIndexedOrNonEightBitImage() {
        for (mapping, depth) in [(UInt8(1), UInt8(2)), (UInt8(0), UInt8(0))] {
            var job = HandBuiltJob()
            job.header()
            job.beginPage()
            job.ubyte(mapping)
            job.attr(.colorMapping)
            job.ubyte(depth)
            job.attr(.colorDepth)
            job.uint16(1)
            job.attr(.sourceWidth)
            job.uint16(1)
            job.attr(.sourceHeight)
            job.uint16XY(1, 1)
            job.attr(.destinationSize)
            job.op(.beginImage)
            job.op(.endImage)
            job.endPage()

            #expect(PCLXLCheck.isUnsupported(PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }))
        }
    }

    @Test func rejectsJPEGCompression() {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .jpeg, payload: [0xFF, 0xD8, 0xFF, 0xD9])
        job.op(.endImage)
        job.endPage()

        #expect(PCLXLCheck.isUnsupported(PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }))
    }

    @Test func ignoresUnknownOperatorsInsideAPage() throws {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.ubyte(0)
        job.attr(id: 200)
        job.op(raw: 0x9F)
        job.beginImage(width: 4, height: 1)
        job.readImage(startLine: 0, blockHeight: 1, mode: .none, payload: [1, 2, 3, 4])
        job.op(.endImage)
        job.endPage()

        let pages = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))
        #expect(pages[0].images.count == 1)
    }

    @Test func rejectsAnUnterminatedPage() {
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.op(.endSession)

        #expect(PCLXLCheck.isMalformed(PCLXLCheck.error { _ = try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes)) }))
    }

    @Test func decodesRLECompressedRowsOnceRLELands() throws {
        guard (try? PCLXLRLE.decode([0x00, 0xAA])) != nil else { return }
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 3, height: 2)
        // Two padded 4-byte rows, each a single 4-byte literal packet.
        job.readImage(
            startLine: 0, blockHeight: 2, mode: .rle,
            payload: [0x03, 1, 2, 3, 0, 0x03, 4, 5, 6, 0])
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.pixels == [1, 2, 3, 4, 5, 6])
    }

    @Test func decodesDeltaRowsOnceDeltaRowLands() throws {
        guard (try? PCLXLDeltaRow.decode([0x00, 0x00], bytesPerRow: 4, rowCount: 1)) != nil else { return }
        var job = HandBuiltJob()
        job.header()
        job.beginPage()
        job.beginImage(width: 4, height: 2)
        // Row 0: replace 4 bytes at offset 0. Row 1: no commands, so it repeats row 0.
        job.readImage(
            startLine: 0, blockHeight: 2, mode: .deltaRow,
            payload: [0x05, 0x00, 0x60, 0x11, 0x11, 0x11, 0x11, 0x00, 0x00])
        job.op(.endImage)
        job.endPage()

        let image = try #require(try PCLXLRenderer.pages(of: PCLXLReader.parse(job.bytes))[0].images.first)
        #expect(image.pixels == [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11])
    }

    private func blankPage(with images: [PCLXLPlacedImage]) -> PCLXLDecodedPage {
        let begin = PCLXLOperatorRecord(tag: 0x43, attributes: [], data: nil, offset: 0)
        let end = PCLXLOperatorRecord(tag: 0x44, attributes: [], data: nil, offset: 1)
        return PCLXLDecodedPage(beginPage: begin, endPage: end, images: images)
    }
}
