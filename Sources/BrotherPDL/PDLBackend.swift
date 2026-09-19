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
public struct PageGeometry: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var dpi: Int
    public var format: PixelFormat

    public init(width: Int, height: Int, dpi: Int, format: PixelFormat) {
        self.width = width
        self.height = height
        self.dpi = dpi
        self.format = format
    }

    public var bytesPerRow: Int { format.bytesPerRow(width: width) }
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
