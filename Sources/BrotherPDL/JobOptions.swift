/// Everything about a job that the print dialog can change. Backends read what applies to them.
public struct JobOptions: Sendable, Equatable {
    public enum ColorMode: Sendable, Equatable {
        /// Colour, but pages whose pixels are all neutral are sent as grayscale so they print with black toner only.
        case auto
        case color
        case mono
    }

    public enum Duplex: Sendable, Equatable {
        case none
        /// Flip on the long edge (book style).
        case longEdge
        /// Flip on the short edge (notepad style).
        case shortEdge
    }

    public enum InputSlot: Sendable, Equatable {
        case auto, tray1, tray2, manual
    }

    public enum Compression: Sendable, Equatable {
        /// Protocol class 2.0; understood by every PCL XL device.
        case rle
        /// Protocol class 2.1; smaller output, enabled once proven on hardware.
        case deltaRow
    }

    public var colorMode: ColorMode = .auto
    public var duplex: Duplex = .none
    public var inputSlot: InputSlot = .auto
    public var media: MediaSize?
    public var tonerSave = false
    public var compression: Compression = .rle
    /// Brother-specific PJL variables were observed ahead of the vendor's host-based language, not
    /// PCL XL, so they can be switched off as a group if a device rejects them.
    public var brotherPJL = true
    /// Ask the printer to print a sheet describing any PCL XL error. For bring-up; wastes paper otherwise.
    public var errorPage = false
    public var jobName: String?

    public init() {}
}
