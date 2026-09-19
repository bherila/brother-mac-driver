/// Decodes jobs in Brother's host-based mono format back into 1-bit pages. Used to check the encoder.
public enum BrotherMonoReader {
    public struct Page: Equatable, Sendable {
        /// Bytes per line, as implied by `bytesPerRow` given to `pages(of:bytesPerRow:)`.
        public var bytesPerRow: Int
        /// Every line of the page, top to bottom, 1 bit per pixel, 1 = black.
        public var lines: [[UInt8]]
        /// Line-data bytes in each block, in order.
        public var blockSizes: [Int]
    }

    static let rasterStart = Array("\u{1B}*b1030m".utf8)

    /// True when `job` looks like this format rather than PCL XL.
    public static func recognizes(_ job: [UInt8]) -> Bool {
        job.firstRange(of: rasterStart) != nil && job.firstRange(of: Array(") HP-PCL XL".utf8)) == nil
    }

    /// Everything before the first page's raster data: the PJL and PCL setup, as text.
    public static func preamble(of job: [UInt8]) -> String {
        String(decoding: job[..<(job.firstRange(of: rasterStart)?.lowerBound ?? job.endIndex)], as: UTF8.self)
    }

    /// The line width is not recorded in the job, so the caller supplies it. `bytesPerRow` may be
    /// given per page (the last value repeats) for jobs that mix page sizes.
    public static func pages(of job: [UInt8], bytesPerRow: [Int]) throws -> [Page] {
        precondition(!bytesPerRow.isEmpty)
        var pages: [Page] = []
        var index = 0
        while let start = job[index...].firstRange(of: rasterStart)?.lowerBound {
            index = start + rasterStart.count
            let width = bytesPerRow[min(pages.count, bytesPerRow.count - 1)]
            var page = Page(bytesPerRow: width, lines: [], blockSizes: [])
            var reference = [UInt8](repeating: 0, count: width)

            while true {
                var length = 0
                var digits = 0
                while index < job.count, (0x30...0x39).contains(job[index]) {
                    length = length * 10 + Int(job[index] - 0x30)
                    index += 1
                    digits += 1
                }
                guard digits > 0, index < job.count else { throw PCLXLError.truncated(offset: index) }
                if job[index] == UInt8(ascii: "M") {
                    guard length == 1030 else { throw PCLXLError.malformed("raster closed with \(length)M at \(index)") }
                    index += 1
                    break
                }
                guard job[index] == UInt8(ascii: "w") else { throw PCLXLError.unexpectedTag(job[index], offset: index) }
                guard length >= 2, index + 1 + length <= job.count else { throw PCLXLError.truncated(offset: index) }
                guard job[index + 1] == 0 else { throw PCLXLError.unexpectedTag(job[index + 1], offset: index + 1) }
                let lineCount = Int(job[index + 2])
                index += 3
                let end = index + length - 2
                for _ in 0..<lineCount {
                    try BrotherMonoLine.decode(job, at: &index, onto: &reference)
                    page.lines.append(reference)
                }
                guard index == end else {
                    throw PCLXLError.malformed("block of \(length - 2) bytes does not match its \(lineCount) lines at \(index)")
                }
                page.blockSizes.append(length - 2)
            }
            pages.append(page)
        }
        return pages
    }
}
