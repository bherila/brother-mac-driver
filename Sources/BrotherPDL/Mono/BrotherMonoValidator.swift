/// Checks a finished job in Brother's host-based mono format the way the printer's firmware would.
///
/// `BrotherMonoReader` decodes a job back into pixels, which answers whether the compression is
/// right. It says nothing about the envelope around those pixels — the PJL variables and their
/// spellings, the PCL reset, the raster start and end, the form feed, the end-of-job block — and
/// that envelope is where a job goes wrong on a printer that has never seen this driver: the
/// pixels are fine and nothing comes out, or a sheet comes out blank.
///
/// Everything checked here is what brlaser's encoder produces, since that is the only encoder
/// known to drive these printers. A finding means this driver has drifted from it.
public enum BrotherMonoValidator {
    /// Block framing limits, from `BrotherMonoBackend` and brlaser.
    static let maxBlockLines = 128
    static let maxBlockBytes = 16350

    /// Validates a complete job. `bytesPerRow` is checked when given; otherwise it is taken from
    /// the first whole line in the job, which is how wide every other line must then be.
    public static func check(job bytes: [UInt8], bytesPerRow: Int? = nil) -> [PDLFinding] {
        var scan = Scan(bytes: bytes, bytesPerRow: bytesPerRow)
        scan.job()
        return scan.findings
    }
}

// MARK: - The scan

/// A cursor over the job that reports what it does not recognise instead of stopping.
private struct Scan {
    let bytes: [UInt8]
    /// The width the caller stated, which holds for the whole job.
    let statedBytesPerRow: Int?
    /// The width in force, the caller's or the one inferred from the page being read.
    var bytesPerRow: Int?
    var findings: [PDLFinding] = []

    private var offset = 0
    private var pages = 0
    private var jobName: String?
    private var sawEOJ = false
    /// Whether a page header has been seen; the first page may not start without one.
    private var configured = false

    private static let uel = PCLXLReader.uel
    private static let rasterStart = Array("\u{1B}*b1030m".utf8)
    private static let rasterEnd = Array("1030M".utf8)
    private static let formFeed: UInt8 = 0x0C

    init(bytes: [UInt8], bytesPerRow: Int?) {
        self.bytes = bytes
        self.statedBytesPerRow = bytesPerRow
        self.bytesPerRow = bytesPerRow
    }

    // MARK: Job

    mutating func job() {
        header()
        var finished = false
        while !finished, offset < bytes.count {
            if matches(Self.rasterStart) {
                page()
                continue
            }
            guard matches(Self.uel) else {
                error("framing", "expected a page, a page header or the end of the job")
                finished = true
                continue
            }
            let lines = pjlBlock()
            if lines.contains(where: { $0.hasPrefix("@PJL EOJ") }) {
                sawEOJ = true
                trailer(lines)
                finished = true
            } else if lines.contains(where: { $0.hasPrefix("@PJL ENTER LANGUAGE") }) {
                pageHeader(lines)
            } else {
                error(
                    "pjl-block",
                    "a UEL block that is neither a page header nor the end of the job: \(lines.joined(separator: "; "))")
                finished = true
            }
        }
        if !sawEOJ {
            error("pjl-eoj", "the job ends without an @PJL EOJ block")
        }
        if pages == 0 {
            warning("page", "the job contains no pages")
        }
    }

    /// 128 NULs to resynchronise a printer stuck mid-job, then the UEL and `@PJL JOB NAME`.
    private mutating func header() {
        var nulls = 0
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
            nulls += 1
        }
        if nulls != 128 {
            warning(
                "framing", "the job opens with \(nulls) NUL bytes; brlaser and this driver send 128", at: 0)
        }
        guard matches(Self.uel) else {
            error("framing", "no UEL after the leading NULs: the printer is never taken into PJL", at: offset)
            return
        }
        let lines = pjlBlock()
        guard let job = lines.first(where: { $0.hasPrefix("@PJL JOB") }) else {
            warning("pjl-job", "the job has no @PJL JOB NAME line, so it is unnamed in the printer's log")
            return
        }
        jobName = quotedValue(of: job, keyword: "@PJL JOB NAME=")
        if jobName == nil {
            error("pjl-job", "cannot read the job name from \(quoted(job))")
        } else if let name = jobName, name.contains("\"") || name.contains("\\") {
            error("pjl-job", "the job name contains a quote or backslash, which PJL cannot escape: \(quoted(name))")
        }
    }

    private mutating func trailer(_ lines: [String]) {
        if let eoj = lines.first(where: { $0.hasPrefix("@PJL EOJ") }) {
            let name = quotedValue(of: eoj, keyword: "@PJL EOJ NAME=")
            if let jobName, name != jobName {
                error("pjl-eoj", "@PJL EOJ names \(quoted(name ?? "")) where @PJL JOB named \(quoted(jobName))")
            }
        }
        guard take(Self.uel) else {
            error("framing", "the EOJ block is not followed by a UEL: the printer is left in PJL", at: offset)
            return
        }
        skipTrailingWhitespace()
        if offset < bytes.count {
            error("framing", "\(bytes.count - offset) bytes follow the end of the job", at: offset)
        }
    }

    // MARK: Page header

    /// `@PJL SET …` lines, then `ENTER LANGUAGE = PCL`, then the PCL reset and copy count.
    private mutating func pageHeader(_ lines: [String]) {
        var seen: Set<String> = []
        var entered = 0
        for line in lines {
            if line == "@PJL" { continue }
            if line.hasPrefix("@PJL ENTER LANGUAGE") {
                entered += 1
                if line != "@PJL ENTER LANGUAGE = PCL" {
                    error("pjl-enter-language", "the page header enters \(quoted(line)), not @PJL ENTER LANGUAGE = PCL")
                }
                continue
            }
            guard line.hasPrefix("@PJL SET ") else {
                error("pjl-line", "unexpected line in a page header: \(quoted(line))")
                continue
            }
            // This family's PJL is spelled with spaces around the `=`, unlike the colour models'.
            let parts = line.dropFirst("@PJL SET ".count).split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[1] == "=" else {
                error("pjl-line", "\(quoted(line)) is not `@PJL SET <VARIABLE> = <VALUE>`")
                continue
            }
            let (variable, value) = (parts[0], parts[2])
            if !seen.insert(variable).inserted {
                error("pjl-line", "the page header sets \(variable) twice")
            }
            guard let allowed = Self.variables[variable] else {
                warning("pjl-variable", "\(variable) is not a variable brlaser sets on these printers")
                continue
            }
            if !allowed.isEmpty && !allowed.contains(value) {
                error(
                    "pjl-variable",
                    "\(variable) is set to \(quoted(value)); brlaser uses \(allowed.sorted().joined(separator: ", "))")
            }
        }
        if lines.last != "@PJL ENTER LANGUAGE = PCL" {
            error("pjl-enter-language", "the page header does not end with @PJL ENTER LANGUAGE = PCL")
        }
        // The first one already left PJL, so anything after it is read as PCL, not as a PJL line.
        if entered > 1 {
            error("pjl-enter-language", "the page header enters a language \(entered) times")
        }
        for required in ["RESOLUTION", "PAPER", "SOURCETRAY", "ECONOMODE"] where !seen.contains(required) {
            error("pjl-variable", "the page header does not set \(required)")
        }
        pclReset()
        configured = true
    }

    /// `ESC E` (reset), `ESC &l1X` (one copy) and, on a duplex model, `ESC &l2S`.
    private mutating func pclReset() {
        guard take(Array("\u{1B}E".utf8)) else {
            error("pcl-reset", "no ESC E after ENTER LANGUAGE: the printer keeps the previous job's settings", at: offset)
            return
        }
        if take(Array("\u{1B}&l1X".utf8)) {
            // One copy, which is what this driver always asks for: copies are produced upstream.
        } else if let copies = escapeValue(prefix: "\u{1B}&l", suffix: "X") {
            warning("pcl-copies", "the page header asks the printer for \(copies) copies", at: offset)
        } else {
            error("pcl-copies", "no ESC &l<n>X copy count after the reset", at: offset)
        }
        _ = take(Array("\u{1B}&l2S".utf8))
    }

    // MARK: Page

    private mutating func page() {
        let start = offset
        guard take(Self.rasterStart) else { return }
        if !configured {
            error("page", "the first page starts without a page header", at: start)
        }
        pages += 1
        // A job may change paper size between pages, so a width inferred from an earlier page says
        // nothing about this one. A width the caller stated covers the whole job and stands.
        bytesPerRow = statedBytesPerRow

        var lines = 0
        while offset < bytes.count {
            if take(Self.rasterEnd) {
                if lines == 0 {
                    warning("page", "page \(pages) carries no raster lines", at: start)
                }
                if !take([Self.formFeed]) {
                    error("page", "page \(pages) is not followed by a form feed, so the sheet never ejects", at: offset)
                }
                return
            }
            guard let count = block() else { return }
            lines += count
        }
        error("page", "page \(pages) is never closed with 1030M", at: start)
    }

    /// `<n>w`, a zero byte, a line count, then that many encoded lines. `n` counts the two bytes
    /// after the `w`, so the line data is `n - 2` bytes long.
    private mutating func block() -> Int? {
        let start = offset
        guard let declared = decimal() else {
            error("block", "expected a block length", at: start)
            return nil
        }
        guard take([UInt8(ascii: "w")]) else {
            error("block", "block length \(declared) is not followed by 'w'", at: offset)
            return nil
        }
        guard offset + 2 <= bytes.count else {
            error("block", "the job ends inside a block header", at: offset)
            return nil
        }
        if bytes[offset] != 0 {
            error("block", "the byte after 'w' is 0x\(String(bytes[offset], radix: 16)), not zero", at: offset)
        }
        let lineCount = Int(bytes[offset + 1])
        offset += 2

        let dataLength = declared - 2
        // Both sides are non-negative and bounded by the job, so this cannot overflow the way
        // `offset + dataLength` can when a malformed block claims a length near Int.max.
        guard dataLength >= 0, dataLength <= bytes.count - offset else {
            error("block", "block claims \(declared) bytes, which runs past the end of the job", at: start)
            return nil
        }
        if lineCount == 0 {
            error("block", "block carries no lines", at: start)
        }
        if lineCount > BrotherMonoValidator.maxBlockLines {
            error(
                "block", "block carries \(lineCount) lines, over the \(BrotherMonoValidator.maxBlockLines) "
                    + "a line count byte can safely describe", at: start)
        }
        if dataLength > BrotherMonoValidator.maxBlockBytes {
            error(
                "block", "block carries \(dataLength) bytes of line data, over brlaser's "
                    + "\(BrotherMonoValidator.maxBlockBytes)", at: start)
        }

        let end = offset + dataLength
        for index in 0..<lineCount {
            guard offset < end else {
                error("block", "block declared \(lineCount) lines and its data ran out after \(index)", at: start)
                offset = end
                return index
            }
            line(firstOfBlock: index == 0, blockStart: start)
        }
        if offset != end {
            error(
                "block", "block's \(lineCount) lines end \(end - offset) bytes short of its declared length",
                at: start)
        }
        offset = end
        return lineCount
    }

    /// One encoded line. The first line of a block may not depend on the line before it, or a
    /// printer that starts decoding at a block boundary produces a garbled page.
    private mutating func line(firstOfBlock: Bool, blockStart: Int) {
        let start = offset
        guard let line = readLine() else { return }
        if line.edits > BrotherMonoLine.maxEdits {
            error("line", "line carries \(line.edits) edits, over the 254 an edit count can hold", at: start)
        }

        // The first line of a block is sent whole, so it also says how wide the row is.
        if bytesPerRow == nil, firstOfBlock, !line.blank, !line.gaps {
            bytesPerRow = line.end
        }
        if let width = bytesPerRow, !line.blank, line.end > width {
            error("line", "line writes \(line.end) bytes into a row of \(width)", at: start)
        }

        // Whole means: every byte of the row is written, so nothing is inherited from the line before.
        let whole = line.blank || (!line.gaps && line.end == (bytesPerRow ?? line.end))
        if firstOfBlock && !whole {
            error(
                "block-standalone",
                "the first line of the block at 0x\(String(blockStart, radix: 16)) is encoded against the line before it",
                at: start)
        }
    }

    private struct Line {
        var edits = 0
        /// Byte after the last one the line writes.
        var end = 0
        /// The single-byte all-white line, which needs nothing from the line before it.
        var blank = false
        /// Some edit skipped bytes, which are then inherited from the line before.
        var gaps = false
    }

    /// Walks a line's edits without needing a row buffer, so a job of unknown width can be checked.
    private mutating func readLine() -> Line? {
        func next() -> Int? {
            guard offset < bytes.count else {
                error("line", "the job ends inside a line", at: offset)
                return nil
            }
            defer { offset += 1 }
            return Int(bytes[offset])
        }
        func extended(_ field: Int, max: Int) -> Int? {
            guard field == max else { return field }
            var value = field
            while true {
                guard let byte = next() else { return nil }
                value += byte
                if byte != 255 { return value }
            }
        }

        guard let edits = next() else { return nil }
        // A blank line is a single 0xFF: the whole row is white, whatever came before it.
        if edits == Int(BrotherMonoLine.blank) {
            return Line(edits: 0, end: bytesPerRow ?? 0, blank: true)
        }

        var line = Line(edits: edits)
        for _ in 0..<edits {
            guard let command = next() else { return nil }
            let isRepeat = command & 0x80 != 0
            guard let gap = extended(isRepeat ? (command >> 5) & 3 : (command >> 3) & 15, max: isRepeat ? 3 : 15),
                let count = extended(isRepeat ? command & 31 : command & 7, max: isRepeat ? 31 : 7)
            else {
                return nil
            }
            if gap > 0 { line.gaps = true }
            line.end += gap + count + (isRepeat ? 2 : 1)
            // A repeat carries one byte; a substitute carries the bytes it writes.
            let payload = isRepeat ? 1 : count + 1
            guard offset + payload <= bytes.count else {
                error("line", "the job ends inside a line's data", at: offset)
                return nil
            }
            offset += payload
        }
        return line
    }

    // MARK: Bytes

    private static let variables: [String: Set<String>] = [
        "RAS1200MODE": ["TRUE", "FALSE"],
        "RESOLUTION": ["300", "600"],
        "ECONOMODE": ["ON", "OFF"],
        "SOURCETRAY": ["AUTO", "T1", "T2", "MANUAL"],
        "MEDIATYPE": ["PLAIN", "THIN", "THICK", "THICKER", "BOND", "TRANSPARENCY", "ENVELOPES", "LABEL", "RECYCLED"],
        "PAPER": ["LETTER", "LEGAL", "A4", "A5", "A6", "B5", "B6", "EXECUTIVE", "C5", "MONARCH", "DL", "COM10"],
        "PAGEPROTECT": ["AUTO", "ON", "OFF"],
        "ORIENTATION": ["PORTRAIT", "LANDSCAPE"],
        // Anything else brlaser sets but whose values are not enumerated here.
        "COPIES": [],
    ]

    private func matches(_ pattern: [UInt8]) -> Bool {
        guard offset + pattern.count <= bytes.count else { return false }
        for (index, byte) in pattern.enumerated() where bytes[offset + index] != byte { return false }
        return true
    }

    private mutating func take(_ pattern: [UInt8]) -> Bool {
        guard matches(pattern) else { return false }
        offset += pattern.count
        return true
    }

    /// The `@PJL …` lines of one UEL-introduced block, consuming the UEL.
    private mutating func pjlBlock() -> [String] {
        guard take(Self.uel) else { return [] }
        var lines: [String] = []
        while matches(Array("@PJL".utf8)) {
            let start = offset
            while offset < bytes.count, bytes[offset] != 0x0A { offset += 1 }
            var end = offset
            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
            lines.append(String(decoding: bytes[start..<end], as: UTF8.self))
            if offset < bytes.count { offset += 1 }
        }
        return lines
    }

    /// A decimal field. Returns nil when there are no digits, and `Int.max` when there are so many
    /// that the value cannot be held — either way the caller rejects it, which beats trapping on a
    /// malformed job this tool exists to read.
    private mutating func decimal() -> Int? {
        var value = 0
        var digits = 0
        var overflowed = false
        while offset < bytes.count, (0x30...0x39).contains(bytes[offset]) {
            let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflow) = scaled.addingReportingOverflow(Int(bytes[offset] - 0x30))
            if scaleOverflow || sumOverflow {
                overflowed = true
            } else {
                value = sum
            }
            offset += 1
            digits += 1
        }
        guard digits > 0 else { return nil }
        return overflowed ? Int.max : value
    }

    /// The number in an escape sequence like `ESC &l<n>X`, consumed when it is there.
    private mutating func escapeValue(prefix: String, suffix: String) -> Int? {
        let mark = offset
        guard take(Array(prefix.utf8)), let value = decimal(), take(Array(suffix.utf8)) else {
            offset = mark
            return nil
        }
        return value
    }

    private mutating func skipTrailingWhitespace() {
        while offset < bytes.count, bytes[offset] == 0x0A || bytes[offset] == 0x0D || bytes[offset] == 0x20 {
            offset += 1
        }
    }

    private func quotedValue(of line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        let rest = line.dropFirst(keyword.count)
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 else { return nil }
        return String(rest.dropFirst().dropLast())
    }

    private func quoted(_ text: String) -> String { "\"\(text)\"" }

    private mutating func error(_ rule: String, _ message: String, at offset: Int? = nil) {
        findings.append(.error(rule, message, at: offset ?? self.offset))
    }

    private mutating func warning(_ rule: String, _ message: String, at offset: Int? = nil) {
        findings.append(.warning(rule, message, at: offset ?? self.offset))
    }
}
