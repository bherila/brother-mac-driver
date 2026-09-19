import BrotherPDL
import CCUPS
import Foundation

extension PxlTool {
    // MARK: - ppd

    /// `pxltool ppd --out <dir> [--model NAME]`: write the PPD for one model, or for all of them.
    static func ppd(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: ["--out", "--model"])
        guard options.path == nil, let directory = options.values["--out"] else {
            throw ToolError.message("usage: pxltool ppd --out <dir> [--model NAME]")
        }

        var models = PrinterModel.all
        if let name = options.values["--model"] {
            guard let model = PrinterModel.named(name) else {
                throw ToolError.message(
                    "unknown model '\(name)'; known: \(PrinterModel.all.map(\.name).joined(separator: ", "))")
            }
            models = [model]
        }

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for model in models {
            let path = "\(directory)/\(model.ppdBaseName).ppd"
            try PPDGenerator.ppd(for: model).write(toFile: path, atomically: true, encoding: .ascii)
            write(path, to: FileHandle.standardOutput)
        }
    }

    // MARK: - compare

    /// `pxltool compare <raster> <job>`: decode the job and check every page, pixel for pixel,
    /// against the CUPS raster it was made from.
    static func compare(_ arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw ToolError.message("usage: pxltool compare <cups-raster-file> <job-file>")
        }
        let pages = try PCLXLRenderer.pages(of: try PCLXLReader.parse(try readInput(arguments[1])))

        let descriptor = open(arguments[0], O_RDONLY)
        guard descriptor >= 0, let raster = cupsRasterOpen(descriptor, CUPS_RASTER_READ) else {
            throw ToolError.message("cannot read raster '\(arguments[0])'")
        }
        defer {
            cupsRasterClose(raster)
            close(descriptor)
        }

        var header = cups_page_header2_t()
        var index = 0
        while cupsRasterReadHeader2(raster, &header) != 0 {
            guard index < pages.count else {
                throw ToolError.message("raster has more pages than the job (\(pages.count))")
            }
            let format: PixelFormat
            switch header.cupsBitsPerPixel {
            case 24: format = .rgb8
            case 8: format = .gray8
            default: throw ToolError.message("page \(index + 1): cannot compare \(header.cupsBitsPerPixel)-bit raster")
            }
            let width = Int(header.cupsWidth)
            let height = Int(header.cupsHeight)
            let bytesPerRow = Int(header.cupsBytesPerLine)

            var expected = [UInt8](repeating: 0, count: bytesPerRow * height)
            let read = expected.withUnsafeMutableBytes { buffer in
                cupsRasterReadPixels(raster, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(buffer.count))
            }
            guard Int(read) == expected.count else {
                throw ToolError.message("page \(index + 1): raster data ended early")
            }

            // The job places images on the sheet; the raster covers only the imageable area within it.
            let scale = Double(header.HWResolution.0) / 72
            let originX = Int((Double(header.cupsImagingBBox.0) * scale).rounded())
            let originY = Int(((Double(header.cupsPageSize.1) - Double(header.cupsImagingBBox.3)) * scale).rounded())
            var page = pages[index]
            page.images = page.images.map { image in
                var shifted = image
                shifted.x -= originX
                shifted.y -= originY
                return shifted
            }
            let actual = try page.composite(width: width, height: height, format: format)
            if let mismatch = zip(expected, actual).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                let bytesPerPixel = format == .rgb8 ? 3 : 1
                let row = mismatch.offset / bytesPerRow
                let column = mismatch.offset % bytesPerRow / bytesPerPixel
                throw ToolError.message(
                    "page \(index + 1): first difference at x=\(column) y=\(row): "
                        + "raster \(mismatch.element.0), job \(mismatch.element.1)")
            }

            let imageFormats = Set(pages[index].images.map { "\($0.format)" }).sorted().joined(separator: "+")
            write(
                "page \(index + 1): \(width)x\(height) \(format) identical "
                    + "(\(pages[index].images.count) images\(imageFormats.isEmpty ? "" : ", " + imageFormats))",
                to: FileHandle.standardOutput)
            index += 1
        }

        guard index == pages.count else {
            throw ToolError.message("job has \(pages.count) pages, raster has \(index)")
        }
    }
}
