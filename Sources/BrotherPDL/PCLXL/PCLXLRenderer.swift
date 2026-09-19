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

    /// Paints the images onto a white canvas of `width` × `height` pixels at 1 user unit = 1 pixel
    /// (images must be unscaled: destination size == source size). Gray images are expanded when
    /// `format` is `.rgb8`; an RGB image on a `.gray8` canvas is an error.
    public func composite(width: Int, height: Int, format: PixelFormat) throws -> [UInt8] {
        throw PCLXLError.unsupported("renderer unimplemented")
    }
}

public enum PCLXLRenderer {
    /// Interprets the operator list: tracks SetColorSpace and SetCursor, and decodes every
    /// BeginImage / ReadImage… / EndImage sequence (no compression, RLE, DeltaRow).
    public static func pages(of stream: PCLXLStream) throws -> [PCLXLDecodedPage] {
        throw PCLXLError.unsupported("renderer unimplemented")
    }
}
