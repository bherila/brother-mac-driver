/// Printer Job Language wrapper shared by every backend.
///
/// Line endings are bare LF and variable spellings follow what Brother's own drivers send.
public enum PJL {
    /// Universal Exit Language: returns the printer to PJL from any language.
    public static let uel: [UInt8] = [0x1B] + Array("%-12345X".utf8)

    /// `UEL @PJL … @PJL ENTER LANGUAGE=<language>` for the start of a job.
    public static func header(language: String, options: JobOptions, grayscale: Bool) -> [UInt8] {
        var lines = ["@PJL "]
        if let name = options.jobName.map(sanitize), !name.isEmpty {
            lines.append("@PJL JOB NAME=\"\(name)\"")
        }
        if options.brotherPJL {
            lines.append("@PJL SET ECONOMODE=\(options.tonerSave ? "ON" : "OFF")")
            lines.append("@PJL SET RESOLUTION=600")
            lines.append("@PJL SET RENDERMODE=\(grayscale ? "GRAYSCALE" : "COLOR")")
            if let tray = sourceTray(options.inputSlot) {
                lines.append("@PJL SET SOURCETRAY=\(tray)")
            }
        }
        lines.append("@PJL ENTER LANGUAGE=\(language)")
        return uel + Array(lines.map { $0 + "\n" }.joined().utf8)
    }

    /// `UEL [@PJL EOJ] UEL` for the end of a job.
    public static func trailer(options: JobOptions) -> [UInt8] {
        guard let name = options.jobName.map(sanitize), !name.isEmpty else { return uel }
        return uel + Array("@PJL EOJ NAME=\"\(name)\"\n".utf8) + uel
    }

    static func sourceTray(_ slot: JobOptions.InputSlot) -> String? {
        switch slot {
        case .auto: "AUTO"
        case .tray1: "TRAY1"
        case .tray2: "TRAY2"
        // Manual feed is selected through the page's MediaSource; there is no PJL spelling for it.
        case .manual: nil
        }
    }

    /// PJL strings are quoted ASCII with no way to escape a quote; keep printable ASCII only, max 80 characters.
    static func sanitize(_ name: String) -> String {
        String(name.unicodeScalars.lazy
            .filter { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" }
            .prefix(80)
            .map(Character.init))
    }
}
