import BrotherPDL
import CCUPS
import CCUPSShim
import Foundation

/// CUPS reads a filter's stderr line by line; the prefix sets the log level (and `PAGE:` does accounting).
enum Log {
    static func debug(_ message: String) { write("DEBUG", message) }
    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }
    /// Page accounting: `PAGE: <page-number> <copies>`.
    static func page(_ number: Int, copies: Int = 1) { write("PAGE", "\(number) \(copies)") }

    private static func write(_ prefix: String, _ message: String) {
        FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
    }
}

struct FilterError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// stdout, which CUPS connects to the backend (USB, socket, …).
enum Stdout {
    static func sink() -> BufferedSink {
        BufferedSink { try writeAll($0) }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Foundation.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FilterError("Unable to send data to the printer: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

/// Job cancellation. CUPS sends SIGTERM; the handler may only set a flag.
enum Cancellation {
    nonisolated(unsafe) private static var flag: sig_atomic_t = 0

    static var isCancelled: Bool { flag != 0 }

    static func install() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in Cancellation.flag = 1 }
    }
}

/// The PPD named by `$PPD`, with defaults and then the job's options marked.
final class MarkedPPD {
    private let ppd: OpaquePointer

    init?(path: String?, jobOptions: String) {
        guard let path, let ppd = brppd_open(path, jobOptions) else { return nil }
        self.ppd = ppd
    }

    deinit {
        brppd_close(ppd)
    }

    /// The marked choice keyword for an option, e.g. `choice("InputSlot") == "Tray1"`.
    func choice(_ option: String) -> String? {
        brppd_marked_choice(ppd, option).map { String(cString: $0) }
    }

    /// The value of a driver-defined attribute, e.g. `*BRBackend: "pclxl"`.
    func attribute(_ name: String) -> String? {
        brppd_attribute(ppd, name).map { String(cString: $0) }
    }
}

extension JobOptions {
    /// Options that come from the PPD's marked choices. Page-level facts (size, duplex) come from the raster header.
    init(ppd: MarkedPPD?, jobTitle: String) {
        self.init()
        jobName = jobTitle
        guard let ppd else { return }

        switch ppd.choice("ColorModel") {
        case "RGB": colorMode = .color
        case "Gray": colorMode = .mono
        default: colorMode = .auto
        }
        switch ppd.choice("InputSlot") {
        case "Tray1": inputSlot = .tray1
        case "Tray2": inputSlot = .tray2
        case "Manual": inputSlot = .manual
        default: inputSlot = .auto
        }
        tonerSave = ppd.choice("BRTonerSaveMode") == "ON"
        compression = ppd.choice("BRCompression") == "DeltaRow" ? .deltaRow : .rle
        brotherPJL = ppd.choice("BRPJL") != "OFF"
        errorPage = ppd.choice("BRErrorPage") == "ON"
    }
}

extension PageGeometry {
    /// Maps a CUPS raster header onto the pixel formats the backends understand.
    init(header: cups_page_header2_t) throws {
        guard header.HWResolution.0 == header.HWResolution.1 else {
            throw FilterError("Unsupported resolution \(header.HWResolution.0)x\(header.HWResolution.1)")
        }
        let format: PixelFormat
        switch (header.cupsColorSpace, header.cupsBitsPerColor, header.cupsBitsPerPixel) {
        case (CUPS_CSPACE_RGB, 8, 24), (CUPS_CSPACE_SRGB, 8, 24):
            guard header.cupsColorOrder == CUPS_ORDER_CHUNKED else {
                throw FilterError("Unsupported colour order \(header.cupsColorOrder.rawValue)")
            }
            format = .rgb8
        case (CUPS_CSPACE_W, 8, 8), (CUPS_CSPACE_SW, 8, 8):
            format = .gray8
        case (CUPS_CSPACE_K, 1, 1):
            format = .black1
        default:
            throw FilterError(
                "Unsupported raster: colorspace \(header.cupsColorSpace.rawValue), "
                    + "\(header.cupsBitsPerColor) bits per colour, \(header.cupsBitsPerPixel) bits per pixel")
        }
        let dpi = Int(header.HWResolution.0)
        self.init(
            width: Int(header.cupsWidth), height: Int(header.cupsHeight), dpi: dpi, format: format,
            mediaPoints: header.sheetPoints, origin: header.rasterOrigin(dpi: dpi))
        guard bytesPerRow == Int(header.cupsBytesPerLine) else {
            throw FilterError("Raster row is \(header.cupsBytesPerLine) bytes, expected \(bytesPerRow)")
        }
    }
}

extension cups_page_header2_t {
    /// Sheet size in points: the exact float value when the rasteriser filled it in, else the integer one.
    var sheetPoints: PageGeometry.Size? {
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
    func rasterOrigin(dpi: Int) -> PageGeometry.Origin {
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
