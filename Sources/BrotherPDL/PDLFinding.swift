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

    /// What kind of claim the finding is making. Keeping these apart matters because they are
    /// answerable by different evidence: a protocol claim is settled by the language definition,
    /// a policy claim by what this driver intends to emit, and a coverage claim by neither — it
    /// says a check was not made. Reporting all three as "the printer will reject this" was
    /// wrong, and is what the eB5Paper and off-sheet-image findings were doing.
    public enum Category: String, Sendable {
        /// The job breaks the printer language, so a printer may reject it.
        case protocolViolation = "protocol"
        /// Legal in the language, but not something this driver should produce.
        case policy
        /// A construct this validator does not model, so the checks that depend on it were
        /// skipped. Not a claim about the job — a claim about the validator.
        case coverage
    }

    public var severity: Severity
    public var category: Category
    /// Short stable name for the rule, so a check can be grepped for and referred to.
    public var rule: String
    public var message: String
    /// Byte offset into the job, where the finding has one.
    public var offset: Int?

    public init(
        severity: Severity, category: Category, rule: String, message: String, offset: Int? = nil
    ) {
        self.severity = severity
        self.category = category
        self.rule = rule
        self.message = message
        self.offset = offset
    }

    /// The job breaks the language. Fails `pxltool check` by default.
    public static func error(_ rule: String, _ message: String, at offset: Int? = nil) -> Self {
        Self(severity: .error, category: .protocolViolation, rule: rule, message: message, offset: offset)
    }

    /// Legal, but not what this driver means to emit. Reported, and fatal only where the job under
    /// check is one this driver produced — which is `--fail-on policy`, the mode CI uses.
    public static func warning(_ rule: String, _ message: String, at offset: Int? = nil) -> Self {
        Self(severity: .warning, category: .policy, rule: rule, message: message, offset: offset)
    }

    /// A check this validator could not make. Never fatal: failing on it would punish a job for
    /// using a part of the language this tool has not learned yet.
    public static func coverage(_ rule: String, _ message: String, at offset: Int? = nil) -> Self {
        Self(severity: .warning, category: .coverage, rule: rule, message: message, offset: offset)
    }

    public var description: String {
        let place = offset.map { " at 0x" + String($0, radix: 16) } ?? ""
        // The category is only worth printing where it is not the one the severity implies, so a
        // protocol error and an ordinary policy warning read exactly as they did before.
        let kind = category == .coverage ? " (unverified)" : ""
        return "\(severity.rawValue)[\(rule)]\(place)\(kind): \(message)"
    }
}

extension [PDLFinding] {
    /// Whether anything here would entitle a printer to reject the job.
    public var hasErrors: Bool { contains { $0.severity == .error } }

    /// Whether anything here says this driver produced something it did not mean to. Worth failing
    /// on for a job this driver wrote, and not for a capture from somewhere else.
    public var hasPolicyViolations: Bool {
        contains { $0.severity == .error || $0.category == .policy }
    }
}
