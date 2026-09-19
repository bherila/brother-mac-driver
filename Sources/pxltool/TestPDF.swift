import BrotherPDL
import CoreGraphics
import CoreText
import Foundation

extension PxlTool {
    /// `pxltool testpdf --out <file> [--size NAME] [--pages N] [--gray yes]`
    ///
    /// A calibration page: a frame on the imageable-area boundary with quarter-inch ticks (to
    /// measure real margins with a ruler), colour bars, a gray ramp, hairlines and text. With
    /// `--gray yes` nothing coloured is drawn, which exercises the driver's neutral-page path.
    static func testPDF(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: ["--out", "--size", "--pages", "--gray"])
        guard options.path == nil, let path = options.values["--out"] else {
            throw ToolError.message("usage: pxltool testpdf --out <file> [--size NAME] [--pages N] [--gray yes]")
        }
        let sizeName = options.values["--size"] ?? "Letter"
        guard let size = MediaSize.named(sizeName) else {
            throw ToolError.message("unknown size '\(sizeName)'; known: \(MediaSize.all.map(\.ppdName).joined(separator: ", "))")
        }
        let pageCount = try options.integer("--pages") ?? 1
        let grayOnly = options.values["--gray"] == "yes"

        var mediaBox = CGRect(x: 0, y: 0, width: size.widthPoints, height: size.heightPoints)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else {
            throw ToolError.message("cannot create '\(path)'")
        }
        for page in 1...pageCount {
            context.beginPDFPage(nil)
            drawCalibrationPage(context, size: size, page: page, of: pageCount, grayOnly: grayOnly)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func drawCalibrationPage(_ context: CGContext, size: MediaSize, page: Int, of pageCount: Int, grayOnly: Bool) {
        let margin = size.marginPoints
        let frame = CGRect(x: 0, y: 0, width: size.widthPoints, height: size.heightPoints).insetBy(dx: margin, dy: margin)

        // Imageable-area frame with a tick every quarter inch, longer on the inch.
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.5)
        context.stroke(frame.insetBy(dx: 0.25, dy: 0.25))
        for step in 0...Int(frame.width / 18) {
            let x = frame.minX + CGFloat(step) * 18
            let length: CGFloat = step.isMultiple(of: 4) ? 10 : 5
            context.strokeLineSegments(between: [
                CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.minY + length),
                CGPoint(x: x, y: frame.maxY), CGPoint(x: x, y: frame.maxY - length),
            ])
        }
        for step in 0...Int(frame.height / 18) {
            let y = frame.minY + CGFloat(step) * 18
            let length: CGFloat = step.isMultiple(of: 4) ? 10 : 5
            context.strokeLineSegments(between: [
                CGPoint(x: frame.minX, y: y), CGPoint(x: frame.minX + length, y: y),
                CGPoint(x: frame.maxX, y: y), CGPoint(x: frame.maxX - length, y: y),
            ])
        }

        let content = frame.insetBy(dx: 24, dy: 24)
        var cursor = content.maxY

        cursor -= 18
        draw("brother-mac-driver calibration page", at: CGPoint(x: content.minX, y: cursor), size: 14, in: context)
        cursor -= 14
        draw(
            "\(size.displayName)  \(Int(size.widthPoints)) x \(Int(size.heightPoints)) pt   page \(page) of \(pageCount)"
                + (pageCount > 1 ? (page.isMultiple(of: 2) ? "   (back)" : "   (front)") : "")
                + "   frame = \(Int(margin)) pt margin, ticks = 1/4 in",
            at: CGPoint(x: content.minX, y: cursor), size: 8, in: context)

        let barHeight = min(60, content.height / 8)
        if !grayOnly {
            cursor -= barHeight + 12
            let colors: [(CGFloat, CGFloat, CGFloat)] = [
                (0, 1, 1), (1, 0, 1), (1, 1, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, 0),
            ]
            let barWidth = content.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
                context.fill(CGRect(x: content.minX + CGFloat(index) * barWidth, y: cursor, width: barWidth, height: barHeight))
            }
        }

        cursor -= barHeight + 12
        let steps = 16
        let stepWidth = content.width / CGFloat(steps)
        for step in 0..<steps {
            context.setFillColor(gray: CGFloat(step) / CGFloat(steps - 1), alpha: 1)
            context.fill(CGRect(x: content.minX + CGFloat(step) * stepWidth, y: cursor, width: stepWidth, height: barHeight))
        }

        // Hairlines from one device pixel (0.12 pt at 600 dpi) upwards.
        cursor -= 12
        context.setStrokeColor(gray: 0, alpha: 1)
        for width in [0.12, 0.24, 0.5, 1.0, 2.0] {
            cursor -= 8
            context.setLineWidth(width)
            context.strokeLineSegments(between: [CGPoint(x: content.minX, y: cursor), CGPoint(x: content.maxX - 60, y: cursor)])
            draw("\(width) pt", at: CGPoint(x: content.maxX - 54, y: cursor - 2), size: 6, in: context)
        }

        cursor -= 24
        for pointSize in [6.0, 8.0, 10.0, 12.0] where cursor - pointSize > content.minY {
            draw(
                "The quick brown fox jumps over the lazy dog 0123456789 (\(Int(pointSize)) pt)",
                at: CGPoint(x: content.minX, y: cursor), size: pointSize, in: context)
            cursor -= pointSize + 6
        }
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
