import BrotherPDL
import CCUPS

// The CUPS raster header, read the same way wherever it is read. The filter turns a header into
// the geometry a backend prints; `pxltool compare` needs the same geometry to line a decoded job
// up with the raster it came from. Two copies of this arithmetic drifted apart once already
// (bherila/brother-mac-driver#24), so there is one.

/// Something in a CUPS raster this driver cannot print.
public struct RasterError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

extension PageGeometry {
    /// Maps a CUPS raster header onto the pixel formats the backends understand.
    public init(header: cups_page_header2_t) throws {
        guard header.HWResolution.0 == header.HWResolution.1 else {
            throw RasterError("Unsupported resolution \(header.HWResolution.0)x\(header.HWResolution.1)")
        }
        let format: PixelFormat
        switch (header.cupsColorSpace, header.cupsBitsPerColor, header.cupsBitsPerPixel) {
        case (CUPS_CSPACE_RGB, 8, 24), (CUPS_CSPACE_SRGB, 8, 24):
            guard header.cupsColorOrder == CUPS_ORDER_CHUNKED else {
                throw RasterError("Unsupported colour order \(header.cupsColorOrder.rawValue)")
            }
            format = .rgb8
        case (CUPS_CSPACE_W, 8, 8), (CUPS_CSPACE_SW, 8, 8):
            format = .gray8
        case (CUPS_CSPACE_K, 1, 1):
            format = .black1
        default:
            throw RasterError(
                "Unsupported raster: colorspace \(header.cupsColorSpace.rawValue), "
                    + "\(header.cupsBitsPerColor) bits per colour, \(header.cupsBitsPerPixel) bits per pixel")
        }
        let dpi = Int(header.HWResolution.0)
        self.init(
            width: Int(header.cupsWidth), height: Int(header.cupsHeight), dpi: dpi, format: format,
            mediaPoints: header.sheetPoints, origin: header.rasterOrigin(dpi: dpi))
        guard bytesPerRow == Int(header.cupsBytesPerLine) else {
            throw RasterError("Raster row is \(header.cupsBytesPerLine) bytes, expected \(bytesPerRow)")
        }
    }
}

extension cups_page_header2_t {
    /// Sheet size in points: the exact float value when the rasteriser filled it in, else the integer one.
    public var sheetPoints: PageGeometry.Size? {
        if cupsPageSize.0 > 0, cupsPageSize.1 > 0 {
            return .init(width: Double(cupsPageSize.0), height: Double(cupsPageSize.1))
        }
        if PageSize.0 > 0, PageSize.1 > 0 {
            return .init(width: Double(PageSize.0), height: Double(PageSize.1))
        }
        return nil
    }

    /// The raster covers the imaging bounding box (left, bottom, right, top in points, origin at the
    /// sheet's bottom-left); this is where its top-left pixel falls, measured from the sheet's top-left.
    public func rasterOrigin(dpi: Int) -> PageGeometry.Origin {
        guard let sheet = sheetPoints else { return .zero }
        var left = Double(cupsImagingBBox.0)
        var top = Double(cupsImagingBBox.3)
        if cupsImagingBBox.2 <= cupsImagingBBox.0 || cupsImagingBBox.3 <= cupsImagingBBox.1 {
            guard ImagingBoundingBox.2 > ImagingBoundingBox.0, ImagingBoundingBox.3 > ImagingBoundingBox.1 else { return .zero }
            left = Double(ImagingBoundingBox.0)
            top = Double(ImagingBoundingBox.3)
        }
        let scale = Double(dpi) / 72
        return .init(x: max(0, Int((left * scale).rounded())), y: max(0, Int(((sheet.height - top) * scale).rounded())))
    }
}
