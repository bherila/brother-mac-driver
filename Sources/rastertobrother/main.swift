import BrotherPDL
import CCUPS
import Foundation

// CUPS filter: argv = job-id user title copies options [file]
// stdin (or file) = CUPS raster, stdout = printer data, stderr = "LEVEL: message" log lines.

func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 6 || arguments.count == 7 else {
        Log.error("Usage: rastertobrother job-id user title copies options [file]")
        return 1
    }

    Cancellation.install()

    var inputFD = STDIN_FILENO
    if arguments.count == 7 {
        inputFD = open(arguments[6], O_RDONLY)
        guard inputFD >= 0 else {
            throw FilterError("Unable to open raster file \(arguments[6]): \(String(cString: strerror(errno)))")
        }
    }
    guard let raster = cupsRasterOpen(inputFD, CUPS_RASTER_READ) else {
        throw FilterError("Unable to read raster stream")
    }
    defer { cupsRasterClose(raster) }

    let ppd = MarkedPPD(path: ProcessInfo.processInfo.environment["PPD"], jobOptions: arguments[5])
    if ppd == nil {
        Log.debug("No usable PPD in $PPD; using default options")
    }
    var options = JobOptions(ppd: ppd, jobTitle: arguments[3])

    // Job-level settings have to be known before the first byte goes out, so read ahead one header.
    var header = cups_page_header2_t()
    guard cupsRasterReadHeader2(raster, &header) != 0 else {
        throw FilterError("No pages found")
    }
    if header.Duplex != CUPS_FALSE {
        options.duplex = header.Tumble != CUPS_FALSE ? .shortEdge : .longEdge
    }

    let backendName = ppd?.attribute("BRBackend") ?? "pclxl"
    Log.debug("backend=\(backendName) options=\(options)")
    switch backendName {
    case "pclxl":
        var backend = PCLXLBackend(options: options)
        try printJob(raster, firstHeader: header, with: &backend)
    default:
        throw FilterError("Unknown backend \"\(backendName)\" in PPD")
    }
    return 0
}

/// Streams every page of the raster through `backend` to stdout. `firstHeader` has already been read.
func printJob(_ raster: OpaquePointer, firstHeader: cups_page_header2_t, with backend: inout some PDLBackend) throws {
    var header = firstHeader
    var sink = Stdout.sink()

    try backend.beginJob(to: &sink)
    var page = 0
    var endedEarly = false
    var row: [UInt8] = []
    pages: repeat {
        page += 1
        let geometry = try PageGeometry(header: header)
        Log.info("Printing page \(page).")
        Log.debug(
            "page \(page): \(geometry.width)x\(geometry.height) \(geometry.dpi)dpi \(geometry.format) "
                + "sheet=\(geometry.sheetPoints.width)x\(geometry.sheetPoints.height)pt origin=\(geometry.origin.x),\(geometry.origin.y)")

        try backend.beginPage(geometry, to: &sink)
        if row.count != geometry.bytesPerRow {
            row = [UInt8](repeating: 0, count: geometry.bytesPerRow)
        }
        for _ in 0..<geometry.height {
            if Cancellation.isCancelled { break pages }
            guard cupsRasterReadPixels(raster, &row, header.cupsBytesPerLine) == header.cupsBytesPerLine else {
                // Close the job cleanly rather than wedging the printer mid-page, then report the failure.
                endedEarly = true
                break pages
            }
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        try backend.endPage(to: &sink)
        try sink.flush()
        Log.page(page)
    } while !Cancellation.isCancelled && cupsRasterReadHeader2(raster, &header) != 0

    if Cancellation.isCancelled {
        Log.info("Job cancelled.")
    }
    try backend.endJob(to: &sink)
    try sink.flush()
    Log.debug("sent \(sink.bytesWritten) bytes for \(page) page(s)")
    // A rasteriser that died upstream must not look like a job that printed in full.
    if endedEarly && !Cancellation.isCancelled {
        throw FilterError("Raster data ended early on page \(page); the job is incomplete")
    }
    Log.info("Ready to print.")
}

do {
    exit(try run())
} catch {
    Log.error("\(error)")
    exit(1)
}
