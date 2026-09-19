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
        let job = try readInput(arguments[1])
        if BrotherMonoReader.recognizes(job) {
            try compareMono(rasterPath: arguments[0], job: job)
            return
        }
        let pages = try PCLXLRenderer.pages(of: try PCLXLReader.parse(job))

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
            // zip stops at the shorter buffer: a short render must not pass as identical.
            guard actual.count == expected.count else {
                throw ToolError.message("page \(index + 1): raster has \(expected.count) bytes, the rendered job \(actual.count)")
            }
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

    /// The mono format does not record the line width, so the raster is read first to learn it.
    private static func compareMono(rasterPath: String, job: [UInt8]) throws {
        let descriptor = open(rasterPath, O_RDONLY)
        guard descriptor >= 0, let raster = cupsRasterOpen(descriptor, CUPS_RASTER_READ) else {
            throw ToolError.message("cannot read raster '\(rasterPath)'")
        }
        defer {
            cupsRasterClose(raster)
            close(descriptor)
        }

        var expected: [(bytesPerRow: Int, height: Int, pixels: [UInt8])] = []
        var header = cups_page_header2_t()
        while cupsRasterReadHeader2(raster, &header) != 0 {
            guard header.cupsBitsPerPixel == 1 else {
                throw ToolError.message("page \(expected.count + 1): a mono job needs a 1-bit raster, got \(header.cupsBitsPerPixel)-bit")
            }
            var pixels = [UInt8](repeating: 0, count: Int(header.cupsBytesPerLine) * Int(header.cupsHeight))
            let read = pixels.withUnsafeMutableBytes { buffer in
                cupsRasterReadPixels(raster, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(buffer.count))
            }
            guard Int(read) == pixels.count else {
                throw ToolError.message("page \(expected.count + 1): raster data ended early")
            }
            expected.append((Int(header.cupsBytesPerLine), Int(header.cupsHeight), pixels))
        }
        guard !expected.isEmpty else { throw ToolError.message("raster has no pages") }

        let pages = try BrotherMonoReader.pages(of: job, bytesPerRow: expected.map(\.bytesPerRow))
        guard pages.count == expected.count else {
            throw ToolError.message("job has \(pages.count) pages, raster has \(expected.count)")
        }
        for (index, (page, want)) in zip(pages, expected).enumerated() {
            guard page.lines.count == want.height else {
                throw ToolError.message("page \(index + 1): job has \(page.lines.count) lines, raster has \(want.height)")
            }
            for (row, line) in page.lines.enumerated() where line[...] != want.pixels[row * want.bytesPerRow..<(row + 1) * want.bytesPerRow] {
                throw ToolError.message("page \(index + 1): first difference on line \(row)")
            }
            write(
                "page \(index + 1): \(want.bytesPerRow * 8)x\(want.height) black1 identical "
                    + "(\(page.blockSizes.count) blocks, largest \(page.blockSizes.max() ?? 0) bytes)",
                to: FileHandle.standardOutput)
        }
    }
}
