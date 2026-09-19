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
    public static let all: [MediaSize] = []

    public static func named(_ ppdName: String) -> MediaSize? {
        all.first { $0.ppdName == ppdName }
    }

    /// The size whose dimensions are within `tolerance` points of the given ones, in either orientation.
    public static func matching(widthPoints: Double, heightPoints: Double, tolerance: Double = 2) -> MediaSize? {
        nil
    }
}
