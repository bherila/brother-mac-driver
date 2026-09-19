/// A printer this driver ships a PPD for.
public struct PrinterModel: Sendable, Equatable {
    public enum Backend: String, Sendable {
        /// Colour PCL XL (PCL 6) raster, 8-bit gray or RGB.
        case pclxl
    }

    /// Unprintable border in points.
    public struct Margins: Sendable, Equatable {
        public var left: Double, bottom: Double, right: Double, top: Double
    }

    /// Model name exactly as the printer reports it in its IEEE-1284 device ID (`MDL:`), e.g. `MFC-9330CDW`.
    public let name: String
    public let backend: Backend
    public let duplex: Bool
    /// Input slots offered in the print dialog, by PPD keyword. `Auto` is always first.
    public let inputSlots: [(keyword: String, displayName: String)]
    /// Page-size keywords this model takes, or nil for everything in `MediaSize.all`.
    public let mediaNames: [String]?
    /// Model-wide margins, or nil to use each `MediaSize`'s own.
    public let margins: Margins?
    /// Pages per minute, for the PPD's informational `*Throughput`.
    public let pagesPerMinute: Int
    /// Whether output has been checked on a real unit of this model.
    public let verified: Bool

    public var color: Bool { backend == .pclxl }
    public var makeAndModel: String { "Brother \(name)" }

    /// File name for the generated PPD, without extension.
    public var ppdBaseName: String { "Brother-\(name.map { $0 == " " ? "-" : $0 }.map(String.init).joined())" }

    public var mediaSizes: [MediaSize] {
        guard let mediaNames else { return MediaSize.all }
        return mediaNames.compactMap(MediaSize.named)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
}

extension PrinterModel {
    private static let traySlots = [("Auto", "Auto Select"), ("Tray1", "Tray 1"), ("Manual", "Manual Feed")]

    public static let all: [PrinterModel] = [
        PrinterModel(
            name: "MFC-9330CDW", backend: .pclxl, duplex: true, inputSlots: traySlots,
            mediaNames: nil, margins: nil, pagesPerMinute: 22, verified: false),
    ]

    /// Looks a model up by its name, ignoring case and a trailing " series".
    public static func named(_ name: String) -> PrinterModel? {
        func key(_ text: String) -> String {
            let lowered = text.lowercased()
            return lowered.hasSuffix(" series") ? String(lowered.dropLast(7)) : lowered
        }
        return all.first { key($0.name) == key(name) }
    }
}
