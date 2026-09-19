/// A paper size the driver offers.
public struct MediaSize: Equatable, Sendable {
    /// PPD `PageSize` keyword, e.g. `Letter`, `EnvDL`.
    public let ppdName: String
    /// Human-readable name for the print dialog, e.g. `US Letter`, `Envelope DL`.
    public let displayName: String
    /// Physical size in PostScript points (1/72 inch), portrait.
    public let widthPoints: Double
    public let heightPoints: Double
    /// Unprintable border on every edge, in points.
    public let marginPoints: Double
    /// Standard PCL XL enumeration, or nil when the size must be sent as CustomMediaSize.
    public let pclxl: PCLXLMediaSize?

    public init(
        ppdName: String, displayName: String, widthPoints: Double, heightPoints: Double,
        marginPoints: Double = 12, pclxl: PCLXLMediaSize?
    ) {
        self.ppdName = ppdName
        self.displayName = displayName
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.marginPoints = marginPoints
        self.pclxl = pclxl
    }

    /// Page size in device pixels at `dpi`, rounded to nearest.
    public func pixelSize(dpi: Int) -> (width: Int, height: Int) {
        (Int((widthPoints * Double(dpi) / 72).rounded()), Int((heightPoints * Double(dpi) / 72).rounded()))
    }
}

extension MediaSize {
    /// Every size offered for the MFC-9330CDW family, in print-dialog order.
    public static let all: [MediaSize] = [
        MediaSize(ppdName: "A4", displayName: "A4", widthPoints: 595, heightPoints: 842, pclxl: .a4),
        MediaSize(ppdName: "Letter", displayName: "US Letter", widthPoints: 612, heightPoints: 792, pclxl: .letter),
        MediaSize(ppdName: "Legal", displayName: "US Legal", widthPoints: 612, heightPoints: 1008, pclxl: .legal),
        MediaSize(ppdName: "Executive", displayName: "Executive", widthPoints: 522, heightPoints: 756, pclxl: .executive),
        MediaSize(ppdName: "A5", displayName: "A5", widthPoints: 420, heightPoints: 595, pclxl: .a5),
        MediaSize(ppdName: "A6", displayName: "A6", widthPoints: 297, heightPoints: 420, pclxl: .a6),
        MediaSize(ppdName: "B5", displayName: "B5 (ISO)", widthPoints: 499, heightPoints: 709, pclxl: .isoB5),
        MediaSize(ppdName: "JISB5", displayName: "B5 (JIS)", widthPoints: 516, heightPoints: 729, pclxl: .jisB5),
        MediaSize(ppdName: "JISB6", displayName: "B6 (JIS)", widthPoints: 363, heightPoints: 516, pclxl: .jisB6),
        MediaSize(ppdName: "EnvDL", displayName: "Envelope DL", widthPoints: 312, heightPoints: 624, pclxl: .dlEnvelope),
        MediaSize(ppdName: "EnvC5", displayName: "Envelope C5", widthPoints: 459, heightPoints: 649, pclxl: .c5Envelope),
        MediaSize(ppdName: "Env10", displayName: "Envelope #10", widthPoints: 297, heightPoints: 684, pclxl: .com10Envelope),
        MediaSize(ppdName: "EnvMonarch", displayName: "Envelope Monarch", widthPoints: 279, heightPoints: 540, pclxl: .monarchEnvelope),
        MediaSize(ppdName: "Br3x5", displayName: "3 × 5 in", widthPoints: 216, heightPoints: 360, pclxl: nil),
        MediaSize(ppdName: "FanFoldGermanLegal", displayName: "Folio", widthPoints: 612, heightPoints: 936, pclxl: nil),
        MediaSize(ppdName: "EnvPRC5Rotated", displayName: "Envelope DL (long edge)", widthPoints: 624, heightPoints: 312, pclxl: nil),
        MediaSize(ppdName: "Postcard", displayName: "Hagaki", widthPoints: 284, heightPoints: 419, pclxl: .jPostcard),
        MediaSize(ppdName: "EnvYou4", displayName: "Envelope You4", widthPoints: 298, heightPoints: 666, pclxl: nil),
        MediaSize(ppdName: "EnvChou3", displayName: "Envelope Chou3", widthPoints: 340, heightPoints: 666, pclxl: nil),
        MediaSize(ppdName: "210x270mm", displayName: "210 × 270 mm", widthPoints: 595, heightPoints: 765, pclxl: nil),
        MediaSize(ppdName: "195x270mm", displayName: "195 × 270 mm (16K)", widthPoints: 553, heightPoints: 765, pclxl: nil),
        MediaSize(ppdName: "184x260mm", displayName: "184 × 260 mm (16K)", widthPoints: 522, heightPoints: 737, pclxl: nil),
        MediaSize(ppdName: "197x273mm", displayName: "197 × 273 mm (16K)", widthPoints: 558, heightPoints: 774, pclxl: nil),
    ]

    public static func named(_ ppdName: String) -> MediaSize? {
        all.first { $0.ppdName == ppdName }
    }

    /// The size whose dimensions are within `tolerance` points of the given ones, in either orientation.
    public static func matching(widthPoints: Double, heightPoints: Double, tolerance: Double = 2) -> MediaSize? {
        var best: MediaSize?
        var bestDistance = Double.greatestFiniteMagnitude

        for size in all {
            let straightMatches =
                abs(size.widthPoints - widthPoints) <= tolerance && abs(size.heightPoints - heightPoints) <= tolerance
            let rotatedMatches =
                abs(size.widthPoints - heightPoints) <= tolerance && abs(size.heightPoints - widthPoints) <= tolerance
            guard straightMatches || rotatedMatches else { continue }

            let straightDistance = abs(size.widthPoints - widthPoints) + abs(size.heightPoints - heightPoints)
            let rotatedDistance = abs(size.widthPoints - heightPoints) + abs(size.heightPoints - widthPoints)
            let distance = min(
                straightMatches ? straightDistance : .greatestFiniteMagnitude,
                rotatedMatches ? rotatedDistance : .greatestFiniteMagnitude
            )

            if distance < bestDistance {
                bestDistance = distance
                best = size
            }
        }

        return best
    }
}
