// Job and block framing as worked out by the brlaser project (Copyright 2013 Peter De Wachter,
// GPL-2.0-or-later). See BrotherMonoLine for the line encoding.

/// Brother's host-based mono laser format (HL-2140 family and relatives): PJL, then PCL used only
/// as an envelope (`ESC *b1030m … 1030M`) around blocks of compressed 1-bit lines.
///
/// Lines are encoded against the previous line. The first line of every band, and the first line
/// after a block fills up, is sent whole so each block can be decoded on its own.
public struct BrotherMonoBackend: PDLBackend {
    /// Lines between forced whole-line encodings.
    static let linesPerBand = 64
    /// The most line data one block may carry.
    static let maxBlockBytes = 16350

    private let options: JobOptions
    private var jobOpen = false
    private var sentHeader: String?

    private var inPage = false
    private var lineIndex = 0
    private var reference: [UInt8] = []
    private var encoded: [UInt8] = []
    private var block: [UInt8] = []
    private var blockLines = 0

    public init(options: JobOptions) {
        self.options = options
    }

    public mutating func beginJob(to sink: inout some ByteSink) throws {
        // A run of NULs lets a printer that is mid-way through a broken job resynchronise.
        try sink.write([UInt8](repeating: 0, count: 128))
        try sink.write(PJL.uel)
        try sink.write(ascii: "@PJL\n@PJL JOB NAME=\"\(jobName)\"\n")
        jobOpen = true
    }

    public mutating func beginPage(_ geometry: PageGeometry, to sink: inout some ByteSink) throws {
        precondition(jobOpen && !inPage, "beginPage outside a job or inside a page")
        guard geometry.format == .black1 else {
            throw PCLXLError.unsupported("mono backend needs 1-bit black raster, got \(geometry.format)")
        }
        guard [300, 600].contains(geometry.dpi) else {
            throw PCLXLError.unsupported("mono backend supports 300 and 600 dpi, got \(geometry.dpi)")
        }

        // The header is repeated only when something in it changes between pages.
        let header = pageHeader(geometry)
        if header != sentHeader {
            try sink.write(PJL.uel)
            try sink.write(ascii: header)
            sentHeader = header
        }
        try sink.write(ascii: "\u{1B}*b1030m")

        inPage = true
        lineIndex = 0
        reference = [UInt8](repeating: 0, count: geometry.bytesPerRow)
    }

    public mutating func writeRow(_ row: UnsafeRawBufferPointer, to sink: inout some ByteSink) throws {
        precondition(inPage, "writeRow outside a page")
        precondition(row.count == reference.count, "row length does not match page geometry")
        let line = row.bindMemory(to: UInt8.self)

        if lineIndex.isMultiple(of: Self.linesPerBand) {
            try flushBlock(to: &sink)
        }
        encode(line, standalone: blockLines == 0)
        if block.count + encoded.count >= Self.maxBlockBytes {
            try flushBlock(to: &sink)
            encode(line, standalone: true)
        }
        block.append(contentsOf: encoded)
        blockLines += 1

        reference.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: line) }
        lineIndex += 1
    }

    public mutating func endPage(to sink: inout some ByteSink) throws {
        precondition(inPage, "endPage outside a page")
        try flushBlock(to: &sink)
        try sink.write(ascii: "1030M\u{0C}")
        inPage = false
    }

    public mutating func endJob(to sink: inout some ByteSink) throws {
        guard jobOpen else { return }
        jobOpen = false
        if inPage {
            // A cancelled job: close the raster envelope so the printer is not left waiting for block
            // data, but send no form feed of our own.
            try flushBlock(to: &sink)
            try sink.write(ascii: "1030M")
            inPage = false
        }
        try sink.write(PJL.uel)
        try sink.write(ascii: "@PJL\n@PJL EOJ NAME=\"\(jobName)\"\n")
        try sink.write(PJL.uel)
        try sink.write(ascii: "\n")
    }

    // MARK: Pieces

    private mutating func encode(_ line: UnsafeBufferPointer<UInt8>, standalone: Bool) {
        encoded.removeAll(keepingCapacity: true)
        if standalone {
            BrotherMonoLine.encode(line, reference: nil, into: &encoded)
        } else {
            reference.withUnsafeBufferPointer { BrotherMonoLine.encode(line, reference: $0, into: &encoded) }
        }
    }

    /// `<n>w`, a zero byte, the line count, then the lines; `n` counts the two bytes after the `w` as well.
    private mutating func flushBlock(to sink: inout some ByteSink) throws {
        guard blockLines > 0 else { return }
        try sink.write(ascii: "\(block.count + 2)w")
        try sink.write([0, UInt8(blockLines)])
        try sink.write(block)
        block.removeAll(keepingCapacity: true)
        blockLines = 0
    }

    private var jobName: String {
        let name = PJL.sanitize(options.jobName ?? "").filter { $0 != "\\" }
        return name.isEmpty ? "Untitled" : name
    }

    private func pageHeader(_ geometry: PageGeometry) -> String {
        let sheet = geometry.sheetPoints
        let paper = MediaSize.matching(widthPoints: sheet.width, heightPoints: sheet.height, allowingRotation: false)
            .flatMap(Self.pjlPaper) ?? "A4"
        var lines = [
            "@PJL",
            "@PJL SET RAS1200MODE = FALSE",
            "@PJL SET RESOLUTION = \(geometry.dpi)",
            "@PJL SET ECONOMODE = \(options.tonerSave ? "ON" : "OFF")",
            "@PJL SET SOURCETRAY = \(sourceTray)",
            "@PJL SET MEDIATYPE = PLAIN",
            "@PJL SET PAPER = \(paper)",
            "@PJL SET PAGEPROTECT = AUTO",
            "@PJL SET ORIENTATION = PORTRAIT",
            "@PJL ENTER LANGUAGE = PCL",
        ].map { $0 + "\n" }.joined()
        // Printer reset, then one copy of each page: copies are produced upstream.
        lines += "\u{1B}E\u{1B}&l1X"
        if options.duplex != .none {
            lines += "\u{1B}&l2S"
        }
        return lines
    }

    private var sourceTray: String {
        switch options.inputSlot {
        case .auto: "AUTO"
        case .tray1: "T1"
        case .tray2: "T2"
        case .manual: "MANUAL"
        }
    }

    /// PJL `PAPER` names, keyed by this driver's page-size keywords.
    static func pjlPaper(_ size: MediaSize) -> String? {
        switch size.ppdName {
        case "A4": "A4"
        case "A5": "A5"
        case "A6": "A6"
        case "B5": "B5"
        case "B6": "B6"
        case "EnvC5": "C5"
        case "EnvMonarch": "MONARCH"
        case "EnvDL": "DL"
        case "Executive": "EXECUTIVE"
        case "Legal": "LEGAL"
        case "Letter": "LETTER"
        default: nil
        }
    }
}
