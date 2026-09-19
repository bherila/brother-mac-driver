// The line encoding below was worked out by the brlaser project (Copyright 2013 Peter De Wachter,
// GPL-2.0-or-later); this is a Swift port of its encoder, with a decoder added for testing.

/// One raster line of Brother's mono-laser host-based format (1 bit per pixel, 1 = black).
///
/// A line is either the single byte `0xFF` (entirely white) or an edit count followed by that
/// many edits, applied left to right against a reference line (the previous line). Each edit
/// starts `offset` bytes after the end of the previous one:
///
/// - substitute, `0b0ooooccc`: replace `c + 1` bytes with the literal bytes that follow
/// - repeat, `0b1oonnnnn`: replace `n + 2` bytes with the single byte that follows
///
/// A field at its maximum (offset 15 / count 7 for substitute, offset 3 / count 31 for repeat)
/// is extended by overflow bytes, each added to the field, continuing while the byte is 255.
/// Overflow bytes for the offset come before those for the count. Bytes no edit touches keep
/// the reference's value.
public enum BrotherMonoLine {
    public static let blank: UInt8 = 0xFF
    /// An edit count of 255 would read as `blank`, so a line gets at most 254 edits.
    static let maxEdits = 254

    /// Appends the encoding of `line`. With a `reference` of the same length the line is encoded as
    /// edits against it; without one, as a single substitute of the whole line (which is how the
    /// first line of a block must be sent).
    public static func encode(
        _ line: UnsafeBufferPointer<UInt8>, reference: UnsafeBufferPointer<UInt8>?, into output: inout [UInt8]
    ) {
        guard line.contains(where: { $0 != 0 }) else {
            output.append(blank)
            return
        }
        guard let reference else {
            output.append(1)
            appendSubstitute(offset: 0, line, 0..<line.count, into: &output)
            return
        }
        precondition(line.count == reference.count, "line and reference differ in length")

        let countIndex = output.count
        output.append(0)
        var edits = 0

        // Trailing bytes equal to the reference need no edit.
        var end = line.count
        while end > 0, line[end - 1] == reference[end - 1] { end -= 1 }

        var position = 0
        while true {
            let editStart = position
            while position < end, line[position] == reference[position] { position += 1 }
            guard position < end else { break }
            let offset = position - editStart

            edits += 1
            if edits == maxEdits {
                appendSubstitute(offset: offset, line, position..<end, into: &output)
                break
            }

            let length = substituteLength(line, reference, from: position, to: end)
            if length > 0 {
                appendSubstitute(offset: offset, line, position..<position + length, into: &output)
                position += length
            } else {
                let value = line[position]
                var run = position + 1
                while run < end, line[run] == value { run += 1 }
                appendRepeat(offset: offset, count: run - position, value: value, into: &output)
                position = run
            }
        }
        output[countIndex] = UInt8(edits)
    }

    /// Decodes one line from `input` starting at `index` (advanced past it) onto `reference`, which becomes the line.
    public static func decode(_ input: [UInt8], at index: inout Int, onto reference: inout [UInt8]) throws {
        func next() throws -> Int {
            guard index < input.count else { throw PCLXLError.truncated(offset: index) }
            defer { index += 1 }
            return Int(input[index])
        }
        func extended(_ field: Int, max: Int) throws -> Int {
            guard field == max else { return field }
            var value = field
            while true {
                let byte = try next()
                value += byte
                if byte != 255 { return value }
            }
        }

        let edits = try next()
        if edits == Int(blank) {
            for position in reference.indices { reference[position] = 0 }
            return
        }
        var position = 0
        for _ in 0..<edits {
            let command = try next()
            if command & 0x80 != 0 {
                position += try extended((command >> 5) & 3, max: 3)
                let count = try extended(command & 31, max: 31) + 2
                let value = UInt8(try next())
                guard position + count <= reference.count else { throw PCLXLError.malformed("repeat runs past the line") }
                for step in 0..<count { reference[position + step] = value }
                position += count
            } else {
                position += try extended((command >> 3) & 15, max: 15)
                let count = try extended(command & 7, max: 7) + 1
                guard position + count <= reference.count else { throw PCLXLError.malformed("substitute runs past the line") }
                for step in 0..<count { reference[position + step] = UInt8(try next()) }
                position += count
            }
        }
    }

    // MARK: Edits

    /// How many bytes from `start` to send literally before something cheaper begins: two bytes in
    /// a row that match the reference again, or a run of three equal bytes (better sent as a repeat).
    /// Zero means a run starts right here.
    private static func substituteLength(
        _ line: UnsafeBufferPointer<UInt8>, _ reference: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int {
        var previous = start
        var current = start
        while current + 1 < end {
            if line[current] == reference[current], line[current + 1] == reference[current + 1] {
                return current - start
            }
            if line[current] == line[current + 1], line[current] == line[previous] {
                return previous - start
            }
            previous = current
            current += 1
        }
        return end - start
    }

    private static func appendSubstitute(
        offset: Int, _ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, into output: inout [UInt8]
    ) {
        let count = range.count - 1
        output.append(UInt8(min(offset, 15) << 3 | min(count, 7)))
        appendOverflow(offset - 15, into: &output)
        appendOverflow(count - 7, into: &output)
        output.append(contentsOf: UnsafeBufferPointer(rebasing: line[range]))
    }

    private static func appendRepeat(offset: Int, count: Int, value: UInt8, into output: inout [UInt8]) {
        let count = count - 2
        output.append(UInt8(0x80 | min(offset, 3) << 5 | min(count, 31)))
        appendOverflow(offset - 3, into: &output)
        appendOverflow(count - 31, into: &output)
        output.append(value)
    }

    /// The part of a field beyond its in-command maximum; nothing is written when the field fitted.
    private static func appendOverflow(_ value: Int, into output: inout [UInt8]) {
        guard value >= 0 else { return }
        output.append(contentsOf: repeatElement(255, count: value / 255))
        output.append(UInt8(value % 255))
    }
}
