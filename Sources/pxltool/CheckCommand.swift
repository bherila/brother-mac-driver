import BrotherPDL
import Foundation

extension PxlTool {
    /// `pxltool check [file] [--bytes-per-row N] [--strict yes]`
    ///
    /// Reads a finished print job and checks it against the rules a printer enforces: the PJL
    /// wrapper, the stream or page framing, every operator's attributes, the row accounting of
    /// every image, and where the images land on the sheet. Nothing is decoded into pixels — that
    /// is what `compare` is for — so this works on a job captured from a queue, where the raster
    /// it came from is long gone.
    ///
    /// Exits non-zero when a printer would be entitled to reject the job, so a script can gate on
    /// it. `--strict yes` also fails on warnings: legal jobs that this driver should not produce.
    static func check(_ arguments: [String]) throws -> Int32 {
        var options = Options()
        try options.parse(arguments, allowed: ["--bytes-per-row", "--strict"])
        let strict = options.values["--strict"] == "yes"
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
        let warnings = findings.count - errors
        let name = options.path.map { $0 == "-" ? "the job" : $0 } ?? "the job"
        write(
            "\(name): \(job.count) bytes of \(language), \(errors) error(s), \(warnings) warning(s)",
            to: FileHandle.standardOutput)
        return errors > 0 || (strict && warnings > 0) ? ExitStatus.failure : ExitStatus.ok
    }
}
