/// An IEEE-1284 device ID: the `KEY:value;` string a printer reports about itself over USB.
public struct DeviceID: Sendable, Equatable {
    public let fields: [String: String]

    public init(_ text: String) {
        var fields: [String: String] = [:]
        for field in text.split(separator: ";") {
            let parts = field.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[Self.trimmed(parts[0]).uppercased()] = Self.trimmed(parts[1])
        }
        self.fields = fields
    }

    /// `MDL` or its long form `MODEL`.
    public var model: String? { fields["MDL"] ?? fields["MODEL"] }

    /// The languages in `CMD` / `COMMAND SET`, upper-cased.
    public var languages: [String] {
        (fields["CMD"] ?? fields["COMMAND SET"] ?? "").split(separator: ",").map { Self.trimmed($0).uppercased() }.filter { !$0.isEmpty }
    }

    public enum Support: Equatable, Sendable {
        /// The model has a PPD in this driver.
        case supported(PrinterModel)
        /// Not a model this driver knows, but it accepts PCL XL, which this driver produces.
        case speaksPCLXL
        case unsupported
    }

    public var support: Support {
        if let model, let known = PrinterModel.named(model) { return .supported(known) }
        return languages.contains { ["PCLXL", "PCL6", "PXL"].contains($0) } ? .speaksPCLXL : .unsupported
    }

    /// One line for a person: the model, what it says it speaks, and what that means here.
    public var summary: String {
        let name = model ?? "unknown model"
        let spoken = languages.isEmpty ? "reports no languages" : "reports languages: \(languages.joined(separator: ", "))"
        switch support {
        case .supported(let known):
            return "\(name) \(spoken) - supported by this driver (\(known.backend.rawValue) backend)"
        case .speaksPCLXL:
            return "\(name) \(spoken) - not in this driver's model list yet, but it accepts PCL XL, which this driver produces"
        case .unsupported:
            return "\(name) \(spoken) - not supported by this driver"
        }
    }

    /// `text` with the value of any serial-number field (`SN:`, `SERN:`, `serial=` …) replaced.
    public static func redactingSerial(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        let keys = ["SERIALNUMBER", "SERIAL", "SERN", "SN"]
        scan: while !rest.isEmpty {
            let boundary = result.last.map { !($0.isLetter || $0.isNumber) } ?? true
            if boundary {
                for key in keys where rest.uppercased().hasPrefix(key) {
                    let afterKey = rest.dropFirst(key.count)
                    guard let separator = afterKey.first, separator == ":" || separator == "=" else { continue }
                    var value = afterKey.dropFirst()
                    if value.first == "\"" {
                        // A quoted value runs to its closing quote, whatever it contains.
                        let quoted = value.dropFirst().prefix { $0 != "\"" }
                        value = value.dropFirst(min(value.count, quoted.count + 2))
                    } else {
                        value = value.drop { $0 != ";" && $0 != "&" && !$0.isWhitespace }
                    }
                    result += rest.prefix(key.count) + String(separator) + "<redacted>"
                    rest = value
                    continue scan
                }
            }
            result.append(rest.removeFirst())
        }
        return result
    }

    private static func trimmed(_ text: Substring) -> String {
        var text = text
        while text.first?.isWhitespace == true { text.removeFirst() }
        while text.last?.isWhitespace == true { text.removeLast() }
        return String(text)
    }
}
