/// Pixel layout of the raster rows handed to a backend.
public enum PixelFormat: Sendable, Equatable {
    /// 8-bit sRGB, 3 bytes per pixel.
    case rgb8
    /// 8-bit grayscale, 1 byte per pixel, 0 = black.
    case gray8
    /// 1-bit black, MSB first, 1 = black. Rows are `(width + 7) / 8` bytes.
    case black1

    public func bytesPerRow(width: Int) -> Int {
        switch self {
        case .rgb8: width * 3
        case .gray8: width
        case .black1: (width + 7) / 8
        }
    }
}

/// Geometry and format of one page of raster, as delivered by the print system.
///
/// The raster normally covers only the imageable area of the sheet, not the whole sheet, so the
/// sheet size and the raster's position on it are carried separately.
public struct PageGeometry: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var dpi: Int
    public var format: PixelFormat
    /// Physical sheet size in points. Nil means the raster is the whole sheet.
    public var mediaPoints: Size?
    /// Where the raster's top-left pixel sits on the sheet, in pixels from the sheet's top-left corner.
    public var origin: Origin

    public struct Size: Sendable, Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Origin: Sendable, Equatable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }

        public static let zero = Origin(x: 0, y: 0)
    }

    public init(
        width: Int, height: Int, dpi: Int, format: PixelFormat, mediaPoints: Size? = nil, origin: Origin = .zero
    ) {
        self.width = width
        self.height = height
        self.dpi = dpi
        self.format = format
        self.mediaPoints = mediaPoints
        self.origin = origin
    }

    public var bytesPerRow: Int { format.bytesPerRow(width: width) }

    /// The sheet size in points: as given, or derived from the raster when it is the whole sheet.
    public var sheetPoints: Size {
        mediaPoints ?? Size(width: Double(width) * 72 / Double(dpi), height: Double(height) * 72 / Double(dpi))
    }
}

/// Where a backend writes device bytes. The filter points this at stdout; tests collect into memory.
public protocol ByteSink {
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws
}

extension ByteSink {
    public mutating func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }

    public mutating func write(ascii string: String) throws {
        try write(Array(string.utf8))
    }
}

/// In-memory sink for tests and tools.
public struct ByteBuffer: ByteSink, Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func write(_ buffer: UnsafeRawBufferPointer) throws {
        bytes.append(contentsOf: buffer)
    }
}

/// One printer language. A job is `beginJob`, then per page `beginPage` / `writeRow`× height /
/// `endPage`, then `endJob`. Rows arrive top to bottom and are streamed: a backend must not
/// require the whole page in memory.
///
/// `endJob` must be safe to call at any point after `beginJob` (including mid-page) so a
/// cancelled job can still leave the printer in a clean state.
public protocol PDLBackend {
    mutating func beginJob(to sink: inout some ByteSink) throws
    mutating func beginPage(_ geometry: PageGeometry, to sink: inout some ByteSink) throws
    mutating func writeRow(_ row: UnsafeRawBufferPointer, to sink: inout some ByteSink) throws
    mutating func endPage(to sink: inout some ByteSink) throws
    mutating func endJob(to sink: inout some ByteSink) throws
}
