import Testing

@testable import BrotherPDL

@Suite struct BrotherMonoBackendTests {
    private func encode(pages: [[[UInt8]]], width: Int, options: JobOptions = JobOptions(), abandon: Bool = false) throws -> [UInt8] {
        var sink = ByteBuffer()
        var backend = BrotherMonoBackend(options: options)
        try backend.beginJob(to: &sink)
        for (index, rows) in pages.enumerated() {
            let geometry = PageGeometry(
                width: width, height: rows.count, dpi: 600, format: .black1,
                mediaPoints: .init(width: 612, height: 792), origin: .init(x: 67, y: 133))
            try backend.beginPage(geometry, to: &sink)
            for row in rows {
                try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
            }
            if !(abandon && index == pages.count - 1) {
                try backend.endPage(to: &sink)
            }
        }
        try backend.endJob(to: &sink)
        return sink.bytes
    }

    /// Splits a job into its text up to the first raster envelope and the decoded lines of each page.
    private func decode(_ job: [UInt8], bytesPerRow: Int) throws -> (preamble: String, pages: [[[UInt8]]], blockSizes: [Int]) {
        let open = Array("\u{1B}*b1030m".utf8)
        var pages: [[[UInt8]]] = []
        var blockSizes: [Int] = []
        var preamble: String?
        var index = 0
        while let start = job[index...].firstRange(of: open)?.lowerBound {
            preamble = preamble ?? String(decoding: job[..<start], as: UTF8.self)
            index = start + open.count
            var lines: [[UInt8]] = []
            var reference = [UInt8](repeating: 0, count: bytesPerRow)
            while true {
                var digits = 0
                var length = 0
                while job[index] >= 0x30, job[index] <= 0x39 {
                    length = length * 10 + Int(job[index] - 0x30)
                    index += 1
                    digits += 1
                }
                try #require(digits > 0)
                if length == 1030, job[index] == UInt8(ascii: "M") {
                    index += 1
                    break
                }
                try #require(job[index] == UInt8(ascii: "w"))
                try #require(job[index + 1] == 0)
                let lineCount = Int(job[index + 2])
                index += 3
                let end = index + length - 2
                blockSizes.append(length - 2)
                for _ in 0..<lineCount {
                    try BrotherMonoLine.decode(job, at: &index, onto: &reference)
                    lines.append(reference)
                }
                try #require(index == end, "block length does not match its lines")
            }
            pages.append(lines)
        }
        return (preamble ?? "", pages, blockSizes)
    }

    private func page(width: Int, height: Int, seed: UInt64) -> [[UInt8]] {
        var state = seed
        let bytesPerRow = (width + 7) / 8
        var row = [UInt8](repeating: 0, count: bytesPerRow)
        return (0..<height).map { y in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            switch Int(truncatingIfNeeded: state >> 40) % 5 {
            case 0: row = [UInt8](repeating: 0, count: bytesPerRow)
            case 1: for x in stride(from: y % 7, to: bytesPerRow, by: 7) { row[x] ^= 0x3C }
            case 2:
                for x in row.indices {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    row[x] = UInt8(truncatingIfNeeded: state >> 33)
                }
            default: break
            }
            return row
        }
    }

    @Test func framing() throws {
        var options = JobOptions()
        options.jobName = "Test \"job\""
        options.inputSlot = .tray1
        options.tonerSave = true
        options.duplex = .longEdge
        let job = try encode(pages: [page(width: 40, height: 3, seed: 1)], width: 40, options: options)
        let text = String(decoding: job, as: UTF8.self)

        #expect(job.prefix(128).allSatisfy { $0 == 0 })
        #expect(job[128] == 0x1B)
        let (preamble, _, _) = try decode(job, bytesPerRow: 5)
        #expect(preamble.hasSuffix(
            "\u{1B}%-12345X@PJL\n@PJL JOB NAME=\"Test job\"\n"
                + "\u{1B}%-12345X@PJL\n@PJL SET RAS1200MODE = FALSE\n@PJL SET RESOLUTION = 600\n@PJL SET ECONOMODE = ON\n"
                + "@PJL SET SOURCETRAY = T1\n@PJL SET MEDIATYPE = PLAIN\n@PJL SET PAPER = LETTER\n"
                + "@PJL SET PAGEPROTECT = AUTO\n@PJL SET ORIENTATION = PORTRAIT\n@PJL ENTER LANGUAGE = PCL\n"
                + "\u{1B}E\u{1B}&l1X\u{1B}&l2S"))
        #expect(text.hasSuffix("1030M\u{0C}\u{1B}%-12345X@PJL\n@PJL EOJ NAME=\"Test job\"\n\u{1B}%-12345X\n"))
    }

    @Test(arguments: [8, 40, 4900, 4901])
    func pagesRoundTrip(width: Int) throws {
        let pages = [page(width: width, height: 300, seed: 3), page(width: width, height: 65, seed: 4)]
        let (_, decoded, blockSizes) = try decode(try encode(pages: pages, width: width), bytesPerRow: (width + 7) / 8)
        #expect(decoded == pages)
        #expect(blockSizes.allSatisfy { $0 < BrotherMonoBackend.maxBlockBytes })
    }

    @Test func pageHeaderIsSentOncePerJobWhenNothingChanges() throws {
        let pages = [page(width: 40, height: 5, seed: 5), page(width: 40, height: 5, seed: 6)]
        let text = String(decoding: try encode(pages: pages, width: 40), as: UTF8.self)
        #expect(text.components(separatedBy: "@PJL ENTER LANGUAGE = PCL").count == 2)
        #expect(text.components(separatedBy: "\u{1B}*b1030m").count == 3)
    }

    @Test func cancelledMidPageClosesTheRasterEnvelopeWithoutAFormFeed() throws {
        let job = try encode(pages: [page(width: 40, height: 100, seed: 7)], width: 40, abandon: true)
        let text = String(decoding: job, as: UTF8.self)
        #expect(text.hasSuffix("1030M\u{1B}%-12345X@PJL\n@PJL EOJ NAME=\"Untitled\"\n\u{1B}%-12345X\n"))
        #expect(try decode(job, bytesPerRow: 5).pages[0].count == 100)
    }

    @Test func rejectsAnythingButOneBitBlack() throws {
        var sink = ByteBuffer()
        var backend = BrotherMonoBackend(options: JobOptions())
        try backend.beginJob(to: &sink)
        #expect(throws: PCLXLError.self) {
            try backend.beginPage(PageGeometry(width: 8, height: 8, dpi: 600, format: .gray8), to: &sink)
        }
    }
}
