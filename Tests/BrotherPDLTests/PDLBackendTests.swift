import Testing

@testable import BrotherPDL

@Suite struct PixelFormatTests {
    @Test(arguments: [
        (PixelFormat.rgb8, 5100, 15300),
        (.gray8, 5100, 5100),
        (.black1, 4760, 595),
        (.black1, 4761, 596),
        (.black1, 1, 1),
    ])
    func bytesPerRow(format: PixelFormat, width: Int, expected: Int) {
        #expect(format.bytesPerRow(width: width) == expected)
        #expect(PageGeometry(width: width, height: 1, dpi: 600, format: format).bytesPerRow == expected)
    }
}

@Suite struct ByteBufferTests {
    @Test func collectsWritesInOrder() throws {
        var sink = ByteBuffer()
        try sink.write(ascii: "@PJL\r\n")
        try sink.write([0x1B, 0x25])
        #expect(sink.bytes == Array("@PJL\r\n".utf8) + [0x1B, 0x25])
    }
}
