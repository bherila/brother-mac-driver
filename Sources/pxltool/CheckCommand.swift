import BrotherPDL
import Foundation

extension PxlTool {
    /// `pxltool check [file] [--bytes-per-row N] [--fail-on errors|policy|all]`
    ///
    /// Reads a finished print job and checks it against the printer language and this driver's
    /// own output rules — which is not a prediction of what a given printer will reject: the PJL
    /// wrapper, the stream or page framing, every operator's attributes, the row accounting of
    /// every image, and where the images land on the sheet. Nothing is decoded into pixels — that
    /// is what `compare` is for — so this works on a job captured from a queue, where the raster
    /// it came from is long gone.
    ///
    /// What counts as failure depends on whose job it is, which is what `--fail-on` picks:
    ///
    /// - `errors` (the default) fails only where the job breaks the printer language. Right for a
    ///   capture from another driver, which is entitled to use the language differently.
    /// - `policy` also fails on legal output this driver should not have produced — an image
    ///   reaching off the sheet, a page scaled, a PJL spelling from the wrong family. Right for a
    ///   job this driver wrote, which is what CI checks.
    /// - `all` additionally fails on the checks that were not made, which is a way of asking
    ///   whether a job uses anything this validator does not model.
    static func check(_ arguments: [String]) throws -> Int32 {
        var options = Options()
        try options.parse(arguments, allowed: ["--bytes-per-row", "--strict", "--fail-on"])
        let failOn = try FailOn(options)
        let job = try readInput(options.path)
        guard !job.isEmpty else {
            throw ToolError.message("the job is empty")
        }

        let language: String
        let findings: [PDLFinding]
        if BrotherMonoReader.recognizes(job) {
            language = "Brother host-based mono"
            findings = BrotherMonoValidator.check(job: job, bytesPerRow: try options.integer("--bytes-per-row"))
        } else {
            language = "PCL XL"
            if options.values["--bytes-per-row"] != nil {
                throw ToolError.message("--bytes-per-row applies to the mono format only; a PCL XL job states its own width")
            }
            findings = PCLXLValidator.check(job: job)
        }

        for finding in findings {
            write("\(finding)", to: FileHandle.standardError)
        }
        let errors = findings.filter { $0.severity == .error }.count
        let policy = findings.filter { $0.severity != .error && $0.category == .policy }.count
        let unverified = findings.filter { $0.category == .coverage }.count
        let name = options.path.map { $0 == "-" ? "the job" : $0 } ?? "the job"
        write(
            "\(name): \(job.count) bytes of \(language), \(errors) error(s), "
                + "\(policy) policy warning(s), \(unverified) unverified",
            to: FileHandle.standardOutput)

        let fatal =
            switch failOn {
            case .errors: errors
            case .policy: errors + policy
            case .all: errors + policy + unverified
            }
        return fatal > 0 ? ExitStatus.failure : ExitStatus.ok
    }

    /// Which findings the caller wants to be fatal.
    private enum FailOn: String {
        case errors, policy, all

        init(_ options: Options) throws {
            // `--strict yes` predates this flag and meant "fail on anything at all".
            if options.values["--strict"] == "yes" {
                self = .all
                return
            }
            guard let name = options.values["--fail-on"] else {
                self = .errors
                return
            }
            guard let parsed = FailOn(rawValue: name) else {
                throw ToolError.message("--fail-on takes errors, policy or all, not \(name)")
            }
            self = parsed
        }
    }
}
