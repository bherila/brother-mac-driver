import BrotherPDL
import CCUPS
import Foundation

// CUPS filter: argv = job-id user title copies options [file]
// stdin (or file) = CUPS raster, stdout = printer data, stderr = "LEVEL: message" log lines.

func log(_ level: String, _ message: String) {
    FileHandle.standardError.write(Data("\(level): \(message)\n".utf8))
}

let arguments = CommandLine.arguments
guard arguments.count == 6 || arguments.count == 7 else {
    log("ERROR", "Usage: rastertobrother job-id user title copies options [file]")
    exit(1)
}

var inputFD: Int32 = 0
if arguments.count == 7 {
    inputFD = open(arguments[6], O_RDONLY)
    guard inputFD >= 0 else {
        log("ERROR", "Unable to open raster file \(arguments[6]): \(String(cString: strerror(errno)))")
        exit(1)
    }
}

guard let raster = cupsRasterOpen(inputFD, CUPS_RASTER_READ) else {
    log("ERROR", "Unable to read raster stream")
    exit(1)
}

// Scaffold behaviour: consume the raster and report each page. Encoding arrives with the PDL backends.
var header = cups_page_header2_t()
var page = 0
while cupsRasterReadHeader2(raster, &header) != 0 {
    page += 1
    log("DEBUG", "page \(page): \(header.cupsWidth)x\(header.cupsHeight) "
        + "\(header.HWResolution.0)dpi bpp=\(header.cupsBitsPerPixel) colorspace=\(header.cupsColorSpace.rawValue)")
    var row = [UInt8](repeating: 0, count: Int(header.cupsBytesPerLine))
    for _ in 0..<header.cupsHeight {
        guard cupsRasterReadPixels(raster, &row, header.cupsBytesPerLine) == header.cupsBytesPerLine else {
            log("ERROR", "Reading pixels failed on page \(page)")
            exit(1)
        }
    }
}
cupsRasterClose(raster)

if page == 0 {
    log("ERROR", "No pages found")
    exit(1)
}
log("INFO", "Ready to print.")
