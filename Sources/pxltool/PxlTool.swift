import BrotherPDL
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exit status conventions shared by the subcommands.
enum ExitStatus {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 64
}

enum ToolError: Error {
    case message(String)
}

enum PxlTool {
    static let usage = """
        usage: pxltool <command> [arguments]

          dump [file]                       list the PJL wrapper, stream header and operators
          render [file] --out <dir>         write page-001.png … for every page
                       [--width W --height H]
          compare <raster> <job>            check a job pixel for pixel against its CUPS raster
          ppd --out <dir> [--model NAME]    write the driver's PPD files
          testpdf --out <file> [--size NAME] [--pages N] [--gray yes]
                                            write a calibration page as PDF

        `file` may be omitted or given as `-` to read the job from standard input.
        """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            write(usage, to: FileHandle.standardError)
            return ExitStatus.usage
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "dump":
                try dump(rest)
            case "render":
                try render(rest)
            case "ppd":
                try ppd(rest)
            case "compare":
                try compare(rest)
            case "testpdf":
                try testPDF(rest)
            case "-h", "--help", "help":
                write(usage, to: FileHandle.standardOutput)
            default:
                write("pxltool: unknown command '\(command)'\n\(usage)", to: FileHandle.standardError)
                return ExitStatus.usage
            }
        } catch let error as ToolError {
            if case .message(let text) = error {
                write("pxltool: \(text)", to: FileHandle.standardError)
            }
            return ExitStatus.failure
        } catch let error as PCLXLError {
            write("pxltool: \(describe(error))", to: FileHandle.standardError)
            return ExitStatus.failure
        } catch {
            write("pxltool: \(error)", to: FileHandle.standardError)
            return ExitStatus.failure
        }
        return ExitStatus.ok
    }

    // MARK: - dump

    private static func dump(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: [])
        let stream = try PCLXLReader.parse(try readInput(options.path))

        var lines: [String] = []
        for line in stream.pjlHeader { lines.append(line) }
        lines.append(stream.streamHeader)

        var pageIndex = 0
        var summaries: [String] = []
        var images = 0
        var compressed = 0
        var pixels = 0
        var inPage = false

        for record in stream.operators {
            lines.append(describe(record))
            switch PCLXLOperator(rawValue: record.tag) {
            case .beginPage:
                inPage = true
                pageIndex += 1
                images = 0
                compressed = 0
                pixels = 0
            case .beginImage:
                images += 1
                let width = record[.sourceWidth]?.intValue ?? 0
                let height = record[.sourceHeight]?.intValue ?? 0
                pixels += width * height
            case .readImage:
                compressed += record.data?.count ?? 0
            case .endPage:
                if inPage {
                    summaries.append(
                        "page \(pageIndex): \(images) image(s), \(compressed) compressed byte(s), "
                            + "\(pixels) decoded pixel(s)")
                }
                inPage = false
            default:
                break
            }
        }
        for line in stream.pjlTrailer { lines.append(line) }
        lines.append(contentsOf: summaries)
        write(lines.joined(separator: "\n"), to: FileHandle.standardOutput)
    }

    private static func describe(_ record: PCLXLOperatorRecord) -> String {
        var text = "0x\(hex(record.offset, width: 6))  \(operatorName(record.tag))"
        for attribute in record.attributes {
            text += " \(attributeName(attribute.id))=\(describe(attribute.value, for: attribute.id))"
        }
        if let data = record.data {
            text += " data=<\(data.count) bytes>"
        }
        return text
    }

    private static func operatorName(_ tag: UInt8) -> String {
        guard let known = PCLXLOperator(rawValue: tag) else { return "op 0x\(hex(Int(tag), width: 2))" }
        return capitalized(String(describing: known))
    }

    private static func attributeName(_ id: UInt8) -> String {
        guard let known = PCLXLAttribute(rawValue: id) else { return "attr\(id)" }
        return capitalized(String(describing: known))
    }

    private static func describe(_ value: PCLXLValue, for id: UInt8) -> String {
        switch value {
        case .integer(let number):
            if let symbol = symbolicName(number, for: id) { return "\(symbol)(\(number))" }
            return "\(number)"
        case .real(let number):
            return "\(number)"
        case .integers(let numbers):
            return "[" + numbers.map(String.init).joined(separator: ", ") + "]"
        case .reals(let numbers):
            return "[" + numbers.map { "\($0)" }.joined(separator: ", ") + "]"
        case .bytes(let bytes):
            if !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                return "\"\(String(decoding: bytes, as: UTF8.self))\""
            }
            return "<\(bytes.count) bytes>"
        }
    }

    /// Symbolic spelling for the attributes whose ubyte values are enumerations.
    private static func symbolicName(_ value: Int, for id: UInt8) -> String? {
        guard let attribute = PCLXLAttribute(rawValue: id), let raw = UInt8(exactly: value) else { return nil }
        let name: String? =
            switch attribute {
            case .colorSpace: PCLXLColorSpace(rawValue: raw).map { String(describing: $0) }
            case .colorDepth: PCLXLColorDepth(rawValue: raw).map { String(describing: $0) }
            case .colorMapping: PCLXLColorMapping(rawValue: raw).map { String(describing: $0) }
            case .compressMode: PCLXLCompressMode(rawValue: raw).map { String(describing: $0) }
            case .dataOrg: PCLXLDataOrg(rawValue: raw).map { String(describing: $0) }
            case .sourceType: PCLXLDataSource(rawValue: raw).map { String(describing: $0) }
            case .measure: PCLXLMeasure(rawValue: raw).map { String(describing: $0) }
            case .errorReport: PCLXLErrorReport(rawValue: raw).map { String(describing: $0) }
            case .orientation: PCLXLOrientation(rawValue: raw).map { String(describing: $0) }
            case .duplexPageMode: PCLXLDuplexPageMode(rawValue: raw).map { String(describing: $0) }
            case .duplexPageSide: PCLXLDuplexPageSide(rawValue: raw).map { String(describing: $0) }
            case .simplexPageMode: PCLXLSimplexPageMode(rawValue: raw).map { String(describing: $0) }
            case .mediaSource: PCLXLMediaSource(rawValue: raw).map { String(describing: $0) }
            case .mediaSize: PCLXLMediaSize(rawValue: raw).map { String(describing: $0) }
            default: nil
            }
        return name.map { $0.hasPrefix("`") ? String($0.dropFirst().dropLast()) : $0 }
    }

    // MARK: - render

    private static func render(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: ["--out", "--width", "--height"])
        guard let directory = options.values["--out"] else {
            throw ToolError.message("render requires --out <dir>")
        }
        let width = try options.integer("--width")
        let height = try options.integer("--height")

        let stream = try PCLXLReader.parse(try readInput(options.path))
        let pages = try PCLXLRenderer.pages(of: stream)
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for (index, page) in pages.enumerated() {
            let format: PixelFormat = page.images.contains { $0.format == .rgb8 } ? .rgb8 : .gray8
            let extent = page.extent
            let pageWidth = max(width ?? extent.width, 1)
            let pageHeight = max(height ?? extent.height, 1)
            let pixels = try page.composite(width: pageWidth, height: pageHeight, format: format)
            let name = "page-" + String(format: "%03d", index + 1) + ".png"
            try writePNG(
                pixels, width: pageWidth, height: pageHeight, format: format,
                to: url.appendingPathComponent(name))
            write("\(name): \(pageWidth)×\(pageHeight) \(format)", to: FileHandle.standardOutput)
        }
        if pages.isEmpty {
            write("no pages in this job", to: FileHandle.standardError)
        }
    }

    private static func writePNG(
        _ pixels: [UInt8], width: Int, height: Int, format: PixelFormat, to url: URL
    ) throws {
        let components = format == .rgb8 ? 3 : 1
        let space = format == .rgb8 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: components * 8,
                bytesPerRow: width * components, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw ToolError.message("could not build an image for \(url.lastPathComponent)")
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ToolError.message("could not create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError.message("could not write \(url.path)")
        }
    }

    // MARK: - support

    /// Hand-rolled argument parsing: one optional positional path plus `--name value` options.
    struct Options {
        var path: String?
        var values: [String: String] = [:]

        mutating func parse(_ arguments: [String], allowed: [String]) throws {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument.hasPrefix("--") {
                    guard allowed.contains(argument) else {
                        throw ToolError.message("unknown option '\(argument)'")
                    }
                    guard index + 1 < arguments.count else {
                        throw ToolError.message("option '\(argument)' needs a value")
                    }
                    values[argument] = arguments[index + 1]
                    index += 2
                    continue
                }
                guard path == nil else { throw ToolError.message("unexpected argument '\(argument)'") }
                path = argument
                index += 1
            }
        }

        func integer(_ name: String) throws -> Int? {
            guard let text = values[name] else { return nil }
            guard let value = Int(text), value > 0 else {
                throw ToolError.message("\(name) needs a positive integer, got '\(text)'")
            }
            return value
        }
    }

    static func readInput(_ path: String?) throws -> [UInt8] {
        guard let path, path != "-" else {
            return Array(FileHandle.standardInput.readDataToEndOfFile())
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolError.message("cannot read '\(path)'")
        }
        return Array(data)
    }

    private static func describe(_ error: PCLXLError) -> String {
        switch error {
        case .truncated(let offset):
            "input ended mid-element at offset 0x\(hex(offset, width: 6)) (\(offset))"
        case .unexpectedTag(let byte, let offset):
            "unexpected tag 0x\(hex(Int(byte), width: 2)) at offset 0x\(hex(offset, width: 6)) (\(offset))"
        case .malformed(let reason):
            "malformed stream: \(reason)"
        case .unsupported(let reason):
            "unsupported: \(reason)"
        }
    }

    private static func hex(_ value: Int, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: false)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data((text + "\n").utf8))
    }
}
