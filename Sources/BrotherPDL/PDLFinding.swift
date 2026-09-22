/// A finding from one of the preflight validators: something about a finished job that a printer
/// would reject, or that this driver should not have produced.
///
/// Both printer languages report through the same type, so a tool can check a job without first
/// knowing which language it is in.
public struct PDLFinding: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable, Comparable {
        /// A printer is entitled to reject the job.
        case error
        /// A legal job that this driver should not be producing.
        case warning

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs == .error && rhs == .warning }
    }

    public var severity: Severity
    /// Short stable name for the rule, so a check can be grepped for and referred to.
    public var rule: String
    public var message: String
    /// Byte offset into the job, where the finding has one.
    public var offset: Int?

    public init(severity: Severity, rule: String, message: String, offset: Int? = nil) {
        self.severity = severity
        self.rule = rule
        self.message = message
        self.offset = offset
    }

    public static func error(_ rule: String, _ message: String, at offset: Int? = nil) -> Self {
        Self(severity: .error, rule: rule, message: message, offset: offset)
    }

    public static func warning(_ rule: String, _ message: String, at offset: Int? = nil) -> Self {
        Self(severity: .warning, rule: rule, message: message, offset: offset)
    }

    public var description: String {
        let place = offset.map { " at 0x" + String($0, radix: 16) } ?? ""
        return "\(severity.rawValue)[\(rule)]\(place): \(message)"
    }
}

extension [PDLFinding] {
    /// Whether anything here would entitle a printer to reject the job.
    public var hasErrors: Bool { contains { $0.severity == .error } }
}
