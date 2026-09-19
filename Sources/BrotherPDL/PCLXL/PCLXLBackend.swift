/// Raster-only PCL XL (PCL 6) for Brother colour lasers with a PCL6 emulation.
///
/// The page is sent as a stack of horizontal bands, each its own image, cropped to the ink it
/// contains; all-white bands are not sent at all. Coordinates are device pixels: the session's
/// units-per-measure equals the raster resolution and the origin is the physical sheet corner, so
/// every image is shifted by the raster's position on the sheet (`PageGeometry.origin`).
///
/// In `.auto` colour mode the gray-or-colour decision is made once per page, never per band, so
/// that a neutral area can't change rendering (black toner vs. composite black) part-way down a
/// page. Neutral rows are held as gray until the page ends (→ whole page sent as gray) or the
/// first coloured pixel arrives (→ held rows are replayed as RGB and the rest streams as RGB).
public struct PCLXLBackend: PDLBackend {
    public static let bandHeight = 128

    private let options: JobOptions
    private var writer = PCLXLWriter()
    private var jobOpen = false
    private var pagesStarted = 0

    private var page: PageState?
    private var origin = PageGeometry.Origin.zero
    private var colorSpace: PCLXLColorSpace?
    private var compressed: [UInt8] = []
    private var convertedRow: [UInt8] = []

    public init(options: JobOptions) {
        self.options = options
    }

    // MARK: PDLBackend

    public mutating func beginJob(to sink: inout some ByteSink) throws {
        try sink.write(PJL.header(language: "PCLXL", options: options, grayscale: options.colorMode == .mono))

        let protocolClass = options.compression == .deltaRow ? (major: 2, minor: 1) : (major: 2, minor: 0)
        writer.streamHeader(protocolClass: protocolClass, comment: "brother-mac-driver")
        // Attribute order within an operator is free; this follows the order in HP's reference.
        writer.uint16XY(600, 600, .unitsPerMeasure)
        writer.enumeration(PCLXLMeasure.inch, .measure)
        writer.enumeration(options.errorPage ? PCLXLErrorReport.errorPage : .backChannel, .errorReport)
        writer.op(.beginSession)
        writer.enumeration(PCLXLDataSource.default, .sourceType)
        writer.enumeration(PCLXLDataOrg.binaryLowByteFirst, .dataOrg)
        writer.op(.openDataSource)
        try flush(to: &sink)
        jobOpen = true
    }

    public mutating func beginPage(_ geometry: PageGeometry, to sink: inout some ByteSink) throws {
        precondition(jobOpen && page == nil, "beginPage outside a job or inside a page")
        guard geometry.format != .black1 else {
            throw PCLXLError.unsupported("PCL XL backend needs 8-bit gray or RGB raster")
        }
        guard geometry.dpi == 600 else {
            throw PCLXLError.unsupported("PCL XL backend is fixed at 600 dpi, got \(geometry.dpi)")
        }

        let bandFormat: PixelFormat = (geometry.format == .gray8 || options.colorMode != .color) ? .gray8 : .rgb8
        page = PageState(
            geometry: geometry,
            deciding: geometry.format == .rgb8 && options.colorMode == .auto,
            band: Band(format: bandFormat, width: geometry.width))
        convertedRow = [UInt8](repeating: 0, count: geometry.width)
        origin = geometry.origin

        writer.enumeration(PCLXLOrientation.portrait, .orientation)
        let sheet = geometry.sheetPoints
        let media = options.media ?? MediaSize.matching(widthPoints: sheet.width, heightPoints: sheet.height)
        if let code = media?.pclxl {
            writer.enumeration(code, .mediaSize)
        } else {
            // Tenths of a millimetre: 254 per inch, 72 points per inch.
            writer.uint16XY(
                Int((sheet.width * 254 / 72).rounded()), Int((sheet.height * 254 / 72).rounded()), .customMediaSize)
            writer.enumeration(PCLXLMeasure.tenthsOfAMillimeter, .customMediaSizeUnits)
        }
        writer.enumeration(mediaSource, .mediaSource)
        switch options.duplex {
        case .none:
            writer.enumeration(PCLXLSimplexPageMode.frontSide, .simplexPageMode)
        case .longEdge, .shortEdge:
            writer.enumeration(
                options.duplex == .longEdge ? PCLXLDuplexPageMode.verticalBinding : .horizontalBinding, .duplexPageMode)
            writer.enumeration(pagesStarted.isMultiple(of: 2) ? PCLXLDuplexPageSide.front : .back, .duplexPageSide)
        }
        writer.op(.beginPage)
        try flush(to: &sink)

        pagesStarted += 1
        // Graphics state, including the colour space, starts fresh on every page.
        colorSpace = nil
    }

    public mutating func writeRow(_ row: UnsafeRawBufferPointer, to sink: inout some ByteSink) throws {
        guard var state = page else { preconditionFailure("writeRow outside a page") }
        page = nil  // keep `state` uniquely referenced while it is mutated
        defer { page = state }
        precondition(row.count == state.geometry.bytesPerRow, "row length does not match page geometry")

        let ink = Self.inkExtent(row)
        switch (state.geometry.format, state.band.format) {
        case (.gray8, _), (.rgb8, .rgb8):
            state.band.append(row, inkBytes: ink)

        case (.rgb8, _):
            // Band is gray: either the page is still undecided, or the job is forced to mono.
            if state.deciding, let ink, !Self.isNeutral(row, inkBytes: ink) {
                try replayHeldAsRGB(&state, to: &sink)
                state.band.append(row, inkBytes: ink)
            } else {
                let neutral = state.deciding
                convertedRow.withUnsafeMutableBytes { Self.toGray(row, into: $0, inkBytes: ink, neutral: neutral) }
                let grayInk = ink.map { $0.lowerBound / 3..<($0.upperBound + 2) / 3 }
                convertedRow.withUnsafeBytes { state.band.append($0, inkBytes: grayInk) }
            }

        case (.black1, _):
            preconditionFailure("rejected in beginPage")
        }

        if state.band.rowCount == Self.bandHeight {
            try finishBand(&state, to: &sink)
        }
    }

    public mutating func endPage(to sink: inout some ByteSink) throws {
        guard var state = page else { preconditionFailure("endPage outside a page") }
        page = nil
        try finishBand(&state, to: &sink)
        for band in state.held {
            try emit(band, to: &sink)
        }
        writer.uint16(1, .pageCopies)
        writer.op(.endPage)
        try flush(to: &sink)
    }

    public mutating func endJob(to sink: inout some ByteSink) throws {
        guard jobOpen else { return }
        jobOpen = false
        if page == nil {
            writer.op(.closeDataSource)
            writer.op(.endSession)
            try flush(to: &sink)
        }
        // Mid-page (a cancelled job): every band went out as a complete image, so the stream is at
        // an operator boundary and the UEL alone abandons the unfinished page.
        page = nil
        try sink.write(PJL.trailer(options: options))
    }

    // MARK: Bands

    private mutating func finishBand(_ state: inout PageState, to sink: inout some ByteSink) throws {
        defer { state.band.startNext() }
        guard let cropped = state.band.cropped() else { return }
        if state.deciding {
            state.held.append(cropped)
        } else {
            try emit(cropped, to: &sink)
        }
    }

    /// The page turned out to contain colour: everything held as gray goes out as RGB, and the
    /// partially filled band is widened in place.
    private mutating func replayHeldAsRGB(_ state: inout PageState, to sink: inout some ByteSink) throws {
        state.deciding = false
        for band in state.held {
            try emit(band.expandedToRGB(), to: &sink)
        }
        state.held.removeAll()
        state.band.expandToRGB()
    }

    private mutating func emit(_ band: CroppedBand, to sink: inout some ByteSink) throws {
        let wanted: PCLXLColorSpace = band.format == .gray8 ? .gray : .rgb
        if colorSpace != wanted {
            writer.enumeration(wanted, .colorSpace)
            writer.op(.setColorSpace)
            colorSpace = wanted
        }

        writer.uint16XY(origin.x + band.x, origin.y + band.y, .point)
        writer.op(.setCursor)

        writer.enumeration(PCLXLColorMapping.directPixel, .colorMapping)
        writer.enumeration(PCLXLColorDepth.bits8, .colorDepth)
        writer.uint16(band.width, .sourceWidth)
        writer.uint16(band.height, .sourceHeight)
        writer.uint16XY(band.width, band.height, .destinationSize)
        writer.op(.beginImage)

        let bytesPerRow = band.format.bytesPerRow(width: band.width)
        compressed.removeAll(keepingCapacity: true)
        band.pixels.withUnsafeBytes { pixels in
            switch options.compression {
            case .rle:
                let padding = [UInt8](repeating: 0, count: -bytesPerRow & 3)
                for row in 0..<band.height {
                    let bytes = UnsafeRawBufferPointer(rebasing: pixels[row * bytesPerRow..<(row + 1) * bytesPerRow])
                    PCLXLRLE.encode(bytes, into: &compressed)
                    if !padding.isEmpty {
                        padding.withUnsafeBytes { PCLXLRLE.encode($0, into: &compressed) }
                    }
                }
            case .deltaRow:
                var delta = PCLXLDeltaRow(bytesPerRow: bytesPerRow)
                for row in 0..<band.height {
                    let bytes = UnsafeRawBufferPointer(rebasing: pixels[row * bytesPerRow..<(row + 1) * bytesPerRow])
                    delta.encode(row: bytes, into: &compressed)
                }
            }
        }

        writer.uint16(0, .startLine)
        writer.uint16(band.height, .blockHeight)
        writer.enumeration(options.compression == .rle ? PCLXLCompressMode.rle : .deltaRow, .compressMode)
        writer.op(.readImage)
        writer.dataLength(compressed.count)
        try flush(to: &sink)
        try sink.write(compressed)

        writer.op(.endImage)
        try flush(to: &sink)
    }

    private mutating func flush(to sink: inout some ByteSink) throws {
        try sink.write(writer.take())
    }

    private var mediaSource: PCLXLMediaSource {
        switch options.inputSlot {
        case .auto: .autoSelect
        case .tray1: .upperCassette
        case .tray2: .lowerCassette
        case .manual: .manualFeed
        }
    }

    // MARK: Row analysis

    /// The byte range of `row` that is not white (0xFF), or nil if the row is blank.
    static func inkExtent(_ row: UnsafeRawBufferPointer) -> Range<Int>? {
        let count = row.count
        var low = 0
        while low + 8 <= count, row.loadUnaligned(fromByteOffset: low, as: UInt64.self) == .max { low += 8 }
        while low < count, row[low] == 0xFF { low += 1 }
        guard low < count else { return nil }
        var high = count
        while high - 8 >= low, row.loadUnaligned(fromByteOffset: high - 8, as: UInt64.self) == .max { high -= 8 }
        while row[high - 1] == 0xFF { high -= 1 }
        return low..<high
    }

    /// Whether every RGB pixel touching `inkBytes` has R == G == B.
    static func isNeutral(_ row: UnsafeRawBufferPointer, inkBytes: Range<Int>) -> Bool {
        var offset = inkBytes.lowerBound / 3 * 3
        while offset < inkBytes.upperBound {
            if row[offset] != row[offset + 1] || row[offset] != row[offset + 2] { return false }
            offset += 3
        }
        return true
    }

    /// RGB → gray for the pixels touching `inkBytes`; white elsewhere. With `neutral` the red channel is the answer.
    static func toGray(
        _ row: UnsafeRawBufferPointer, into gray: UnsafeMutableRawBufferPointer, inkBytes: Range<Int>?, neutral: Bool
    ) {
        _ = gray.initializeMemory(as: UInt8.self, repeating: 0xFF)
        guard let inkBytes else { return }
        for pixel in inkBytes.lowerBound / 3..<(inkBytes.upperBound + 2) / 3 {
            let r = Int(row[pixel * 3]), g = Int(row[pixel * 3 + 1]), b = Int(row[pixel * 3 + 2])
            // Rec. 601 luma in 8.8 fixed point; the weights sum to 256 so white stays white.
            gray[pixel] = neutral ? UInt8(r) : UInt8((77 * r + 150 * g + 29 * b + 128) >> 8)
        }
    }
}

// MARK: - Page state

private struct PageState {
    var geometry: PageGeometry
    /// `.auto` colour mode and no coloured pixel seen yet: bands are gray and held rather than sent.
    var deciding: Bool
    var band: Band
    var held: [CroppedBand] = []
}

/// A band cropped to its ink, ready to become one image.
private struct CroppedBand {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var format: PixelFormat
    var pixels: [UInt8]

    func expandedToRGB() -> CroppedBand {
        precondition(format == .gray8)
        var copy = self
        copy.format = .rgb8
        copy.pixels = Band.expand(gray: pixels)
        return copy
    }
}

/// Accumulates up to `PCLXLBackend.bandHeight` full-width rows and tracks where the ink is.
private struct Band {
    private(set) var format: PixelFormat
    let width: Int
    private(set) var y = 0
    private(set) var rowCount = 0
    private var rows: [UInt8] = []
    private var inkColumns: Range<Int>?
    private var inkRows: Range<Int>?

    init(format: PixelFormat, width: Int) {
        self.format = format
        self.width = width
        rows.reserveCapacity(format.bytesPerRow(width: width) * PCLXLBackend.bandHeight)
    }

    /// `inkBytes` is the non-white byte range of `row`, which must already be in the band's format.
    mutating func append(_ row: UnsafeRawBufferPointer, inkBytes: Range<Int>?) {
        rows.append(contentsOf: row)
        if let inkBytes {
            let bytesPerPixel = format == .rgb8 ? 3 : 1
            let columns = inkBytes.lowerBound / bytesPerPixel..<(inkBytes.upperBound + bytesPerPixel - 1) / bytesPerPixel
            inkColumns = inkColumns.map { min($0.lowerBound, columns.lowerBound)..<max($0.upperBound, columns.upperBound) } ?? columns
            inkRows = (inkRows?.lowerBound ?? rowCount)..<rowCount + 1
        }
        rowCount += 1
    }

    mutating func startNext() {
        y += rowCount
        rowCount = 0
        rows.removeAll(keepingCapacity: true)
        inkColumns = nil
        inkRows = nil
    }

    /// The ink-bearing rectangle of the band, or nil if the band is blank.
    func cropped() -> CroppedBand? {
        guard let inkColumns, let inkRows else { return nil }
        let bytesPerPixel = format == .rgb8 ? 3 : 1
        let stride = format.bytesPerRow(width: width)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(inkColumns.count * bytesPerPixel * inkRows.count)
        for row in inkRows {
            let start = row * stride + inkColumns.lowerBound * bytesPerPixel
            pixels.append(contentsOf: rows[start..<start + inkColumns.count * bytesPerPixel])
        }
        return CroppedBand(
            x: inkColumns.lowerBound, y: y + inkRows.lowerBound, width: inkColumns.count, height: inkRows.count,
            format: format, pixels: pixels)
    }

    mutating func expandToRGB() {
        precondition(format == .gray8)
        format = .rgb8
        rows = Band.expand(gray: rows)
        rows.reserveCapacity(format.bytesPerRow(width: width) * PCLXLBackend.bandHeight)
    }

    static func expand(gray: [UInt8]) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: gray.count * 3) { buffer, count in
            for (index, value) in gray.enumerated() {
                buffer[index * 3] = value
                buffer[index * 3 + 1] = value
                buffer[index * 3 + 2] = value
            }
            count = gray.count * 3
        }
    }
}
