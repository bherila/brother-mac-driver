/// One image as placed on a page, fully decompressed.
public struct PCLXLPlacedImage: Equatable, Sendable {
    /// Cursor position when BeginImage ran, in session user units (top-left origin).
    public var x: Int
    public var y: Int
    /// Source size in pixels.
    public var width: Int
    public var height: Int
    /// DestinationSize in session user units.
    public var destinationWidth: Int
    public var destinationHeight: Int
    /// `.rgb8` or `.gray8`.
    public var format: PixelFormat
    /// `height` rows of `format.bytesPerRow(width:)` bytes, row padding removed.
    public var pixels: [UInt8]

    public init(
        x: Int, y: Int, width: Int, height: Int, destinationWidth: Int, destinationHeight: Int,
        format: PixelFormat, pixels: [UInt8]
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.destinationWidth = destinationWidth
        self.destinationHeight = destinationHeight
        self.format = format
        self.pixels = pixels
    }
}

/// Everything the renderer learned about one BeginPage…EndPage span.
public struct PCLXLDecodedPage: Equatable, Sendable {
    /// The BeginPage operator, for inspecting media/orientation/duplex attributes.
    public var beginPage: PCLXLOperatorRecord
    /// The EndPage operator (PageCopies lives here).
    public var endPage: PCLXLOperatorRecord
    public var images: [PCLXLPlacedImage]

    public init(beginPage: PCLXLOperatorRecord, endPage: PCLXLOperatorRecord, images: [PCLXLPlacedImage]) {
        self.beginPage = beginPage
        self.endPage = endPage
        self.images = images
    }

    /// The smallest canvas that contains every image, i.e. `max(x + width)` × `max(y + height)`.
    public var extent: (width: Int, height: Int) {
        var width = 0
        var height = 0
        for image in images {
            width = max(width, image.x + image.width)
            height = max(height, image.y + image.height)
        }
        return (width, height)
    }

    /// Paints the images onto a white canvas of `width` × `height` pixels at 1 user unit = 1 pixel
    /// (images must be unscaled: destination size == source size). Gray images are expanded when
    /// `format` is `.rgb8`; an RGB image on a `.gray8` canvas is an error.
    public func composite(width: Int, height: Int, format: PixelFormat) throws -> [UInt8] {
        guard width >= 0, height >= 0 else { throw PCLXLError.malformed("negative canvas size") }
        let canvasPixelSize: Int
        switch format {
        case .rgb8: canvasPixelSize = 3
        case .gray8: canvasPixelSize = 1
        case .black1: throw PCLXLError.unsupported("composite onto a 1-bit canvas")
        }
        let canvasBytesPerRow = format.bytesPerRow(width: width)
        var canvas = [UInt8](repeating: 0xFF, count: canvasBytesPerRow * height)

        for image in images {
            guard image.destinationWidth == image.width, image.destinationHeight == image.height else {
                throw PCLXLError.unsupported(
                    "scaled image: source \(image.width)×\(image.height) into "
                        + "\(image.destinationWidth)×\(image.destinationHeight)")
            }
            let sourcePixelSize: Int
            switch (format, image.format) {
            case (.rgb8, .rgb8), (.gray8, .gray8): sourcePixelSize = canvasPixelSize
            case (.rgb8, .gray8): sourcePixelSize = 1
            case (.gray8, .rgb8):
                throw PCLXLError.unsupported("RGB image on a grayscale canvas")
            default:
                throw PCLXLError.unsupported("image format \(image.format) on a \(format) canvas")
            }
            let sourceBytesPerRow = image.format.bytesPerRow(width: image.width)
            guard image.pixels.count >= sourceBytesPerRow * image.height else {
                throw PCLXLError.malformed("placed image has fewer rows than its height")
            }

            for row in 0..<image.height {
                let destinationRow = image.y + row
                guard destinationRow >= 0, destinationRow < height else { continue }
                let sourceRowStart = row * sourceBytesPerRow
                let destinationRowStart = destinationRow * canvasBytesPerRow
                for column in 0..<image.width {
                    let destinationColumn = image.x + column
                    guard destinationColumn >= 0, destinationColumn < width else { continue }
                    let source = sourceRowStart + column * sourcePixelSize
                    let destination = destinationRowStart + destinationColumn * canvasPixelSize
                    if sourcePixelSize == canvasPixelSize {
                        for byte in 0..<canvasPixelSize {
                            canvas[destination + byte] = image.pixels[source + byte]
                        }
                    } else {
                        let gray = image.pixels[source]
                        canvas[destination] = gray
                        canvas[destination + 1] = gray
                        canvas[destination + 2] = gray
                    }
                }
            }
        }
        return canvas
    }
}

public enum PCLXLRenderer {
    /// Interprets the operator list: tracks SetColorSpace and SetCursor, and decodes every
    /// BeginImage / ReadImage… / EndImage sequence (no compression, RLE, DeltaRow).
    public static func pages(of stream: PCLXLStream) throws -> [PCLXLDecodedPage] {
        var pages: [PCLXLDecodedPage] = []
        var colorSpace = PixelFormat.gray8
        var cursorX = 0
        var cursorY = 0
        var beginPage: PCLXLOperatorRecord?
        var images: [PCLXLPlacedImage] = []
        var image: ImageState?

        for record in stream.operators {
            switch PCLXLOperator(rawValue: record.tag) {
            case .beginPage:
                guard beginPage == nil else { throw PCLXLError.malformed("BeginPage inside a page") }
                colorSpace = .gray8
                cursorX = 0
                cursorY = 0
                images = []
                beginPage = record

            case .endPage:
                guard let started = beginPage else {
                    throw PCLXLError.malformed("EndPage without BeginPage at offset \(record.offset)")
                }
                guard image == nil else {
                    throw PCLXLError.malformed("EndPage inside an image at offset \(record.offset)")
                }
                pages.append(PCLXLDecodedPage(beginPage: started, endPage: record, images: images))
                beginPage = nil
                images = []

            case .setColorSpace:
                guard let raw = record[.colorSpace]?.intValue, raw <= 0xFF,
                    let space = PCLXLColorSpace(rawValue: UInt8(truncatingIfNeeded: raw))
                else {
                    throw PCLXLError.unsupported("SetColorSpace at offset \(record.offset)")
                }
                switch space {
                case .gray: colorSpace = .gray8
                case .rgb, .sRGB: colorSpace = .rgb8
                }

            case .setCursor:
                guard let point = record[.point]?.intArray, point.count == 2 else {
                    throw PCLXLError.malformed("SetCursor without a Point xy at offset \(record.offset)")
                }
                cursorX = point[0]
                cursorY = point[1]

            case .beginImage:
                guard beginPage != nil else {
                    throw PCLXLError.malformed("BeginImage outside a page at offset \(record.offset)")
                }
                guard image == nil else {
                    throw PCLXLError.malformed("BeginImage inside an image at offset \(record.offset)")
                }
                image = try makeImageState(record, colorSpace: colorSpace, x: cursorX, y: cursorY)

            case .readImage:
                guard var state = image else {
                    throw PCLXLError.malformed("ReadImage outside an image at offset \(record.offset)")
                }
                try read(record, into: &state)
                image = state

            case .endImage:
                guard let state = image else {
                    throw PCLXLError.malformed("EndImage without BeginImage at offset \(record.offset)")
                }
                guard state.rowsReceived == state.height else {
                    throw PCLXLError.malformed(
                        "image has \(state.rowsReceived) of \(state.height) rows at offset \(record.offset)")
                }
                images.append(
                    PCLXLPlacedImage(
                        x: state.x, y: state.y, width: state.width, height: state.height,
                        destinationWidth: state.destinationWidth, destinationHeight: state.destinationHeight,
                        format: state.format, pixels: state.pixels))
                image = nil

            default:
                continue
            }
        }

        guard beginPage == nil else { throw PCLXLError.malformed("BeginPage without EndPage") }
        return pages
    }

    private static func makeImageState(
        _ record: PCLXLOperatorRecord, colorSpace: PixelFormat, x: Int, y: Int
    ) throws -> ImageState {
        let mapping = try requiredInt(record, .colorMapping)
        guard mapping == Int(PCLXLColorMapping.directPixel.rawValue) else {
            throw PCLXLError.unsupported("ColorMapping \(mapping)")
        }
        let depth = try requiredInt(record, .colorDepth)
        guard depth == Int(PCLXLColorDepth.bits8.rawValue) else {
            throw PCLXLError.unsupported("ColorDepth \(depth)")
        }
        let width = try requiredInt(record, .sourceWidth)
        let height = try requiredInt(record, .sourceHeight)
        guard width > 0, height > 0 else {
            throw PCLXLError.malformed("BeginImage source size \(width)×\(height)")
        }
        guard let destination = record[.destinationSize]?.intArray, destination.count == 2 else {
            throw PCLXLError.malformed("BeginImage without a DestinationSize xy at offset \(record.offset)")
        }
        return ImageState(
            x: x, y: y, width: width, height: height,
            destinationWidth: destination[0], destinationHeight: destination[1],
            format: colorSpace, pixels: [], rowsReceived: 0)
    }

    private static func read(_ record: PCLXLOperatorRecord, into state: inout ImageState) throws {
        let startLine = try requiredInt(record, .startLine)
        let blockHeight = try requiredInt(record, .blockHeight)
        let rawMode = try requiredInt(record, .compressMode)
        guard rawMode <= 0xFF, let mode = PCLXLCompressMode(rawValue: UInt8(truncatingIfNeeded: rawMode)) else {
            throw PCLXLError.unsupported("CompressMode \(rawMode)")
        }
        guard startLine == state.rowsReceived else {
            throw PCLXLError.malformed(
                "ReadImage StartLine \(startLine) but \(state.rowsReceived) rows received, at offset \(record.offset)")
        }
        guard blockHeight >= 0, state.rowsReceived + blockHeight <= state.height else {
            throw PCLXLError.malformed(
                "ReadImage block of \(blockHeight) rows overruns SourceHeight \(state.height)")
        }
        if blockHeight == 0 { return }
        guard let data = record.data else {
            throw PCLXLError.malformed("ReadImage without embedded data at offset \(record.offset)")
        }

        let bytesPerRow = state.format.bytesPerRow(width: state.width)
        let padding = record[.padBytesMultiple]?.intValue ?? 4
        let paddedBytesPerRow = padding > 1 ? (bytesPerRow + padding - 1) / padding * padding : bytesPerRow

        switch mode {
        case .none:
            try append(data, rowStride: paddedBytesPerRow, rows: blockHeight, into: &state, at: record.offset)
        case .rle:
            let decoded = try PCLXLRLE.decode(data)
            try append(decoded, rowStride: paddedBytesPerRow, rows: blockHeight, into: &state, at: record.offset)
        case .deltaRow:
            let decoded = try PCLXLDeltaRow.decode(data, bytesPerRow: bytesPerRow, rowCount: blockHeight)
            try append(decoded, rowStride: bytesPerRow, rows: blockHeight, into: &state, at: record.offset)
        case .jpeg:
            throw PCLXLError.unsupported("JPEG image compression")
        }
    }

    /// Copies `rows` rows of `rowStride` bytes, keeping only the leading `bytesPerRow` of each.
    private static func append(
        _ rows: [UInt8], rowStride: Int, rows count: Int, into state: inout ImageState, at offset: Int
    ) throws {
        let bytesPerRow = state.format.bytesPerRow(width: state.width)
        guard rows.count >= rowStride * count else { throw PCLXLError.truncated(offset: offset) }
        state.pixels.reserveCapacity(state.pixels.count + bytesPerRow * count)
        for row in 0..<count {
            let start = row * rowStride
            state.pixels.append(contentsOf: rows[start..<(start + bytesPerRow)])
        }
        state.rowsReceived += count
    }

    private static func requiredInt(_ record: PCLXLOperatorRecord, _ attribute: PCLXLAttribute) throws -> Int {
        guard let value = record[attribute]?.intValue else {
            throw PCLXLError.malformed("missing \(attribute) on operator 0x\(hex(record.tag)) at offset \(record.offset)")
        }
        return value
    }

    private static func hex(_ byte: UInt8) -> String {
        let digits = "0123456789ABCDEF"
        let high = digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))]
        let low = digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))]
        return "\(high)\(low)"
    }
}

/// An image being accumulated between BeginImage and EndImage.
private struct ImageState {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var destinationWidth: Int
    var destinationHeight: Int
    var format: PixelFormat
    var pixels: [UInt8]
    var rowsReceived: Int
}
