import Testing

@testable import BrotherPDL

// As with the PCL XL validator: every check starts from a job the real backend produced and
// breaks one thing in it, so a rule that never fires would show up as a failing test here.

// MARK: - Helpers

/// A job from the real encoder: `pages` pages with a black bar down the left of each.
private func goodJob(
    pages: Int = 1, width: Int = 512, height: Int = 200, options: JobOptions = JobOptions(),
    abandonLastPage: Bool = false
) throws -> [UInt8] {
    var sink = ByteBuffer()
    var backend = BrotherMonoBackend(options: options)
    let geometry = PageGeometry(
        width: width, height: height, dpi: 600, format: .black1,
        mediaPoints: .init(width: 612, height: 792))
    var row = [UInt8](repeating: 0, count: geometry.bytesPerRow)
    for index in 0..<4 { row[index] = 0xFF }

    try backend.beginJob(to: &sink)
    for page in 0..<pages {
        try backend.beginPage(geometry, to: &sink)
        for _ in 0..<height {
            try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
        }
        if !(abandonLastPage && page == pages - 1) {
            try backend.endPage(to: &sink)
        }
    }
    try backend.endJob(to: &sink)
    return sink.bytes
}

private func rules(_ findings: [PDLFinding]) -> [String] {
    findings.map(\.rule)
}

private func patched(_ job: [UInt8], replacing pattern: [UInt8], with replacement: [UInt8]) -> [UInt8] {
    guard let range = job.firstRange(of: pattern) else {
        Issue.record("pattern is not in the job")
        return job
    }
    var copy = job
    copy.replaceSubrange(range, with: replacement)
    return copy
}

private func patched(_ job: [UInt8], replacing text: String, with replacement: String) -> [UInt8] {
    patched(job, replacing: Array(text.utf8), with: Array(replacement.utf8))
}

// MARK: - A good job passes

@Suite struct BrotherMonoValidatorCleanJobTests {
    @Test func aJobFromTheEncoderHasNothingWrongWithIt() throws {
        let findings = BrotherMonoValidator.check(job: try goodJob())
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test(arguments: [1, 2, 4]) func multiPageJobsPass(pages: Int) throws {
        let findings = BrotherMonoValidator.check(job: try goodJob(pages: pages))
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func tonerSaveAndTraySelectionPass() throws {
        var options = JobOptions()
        options.tonerSave = true
        options.inputSlot = .tray1
        options.jobName = "mono validator test"
        let findings = BrotherMonoValidator.check(job: try goodJob(options: options))
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func theRowWidthIsCheckedWhenTheCallerKnowsIt() throws {
        // 512 pixels is 64 bytes per row; nothing in the job itself states that.
        #expect(BrotherMonoValidator.check(job: try goodJob(), bytesPerRow: 64).isEmpty)
        #expect(BrotherMonoValidator.check(job: try goodJob(), bytesPerRow: 32).hasErrors)
    }

    @Test func aPageTallerThanOneBlockPasses() throws {
        // Blocks hold 64 lines, so this job is several blocks, each of which must stand on its own.
        let findings = BrotherMonoValidator.check(job: try goodJob(height: 600))
        #expect(findings.isEmpty, "\(findings)")
    }
}

// MARK: - Job framing

@Suite struct BrotherMonoValidatorFramingTests {
    @Test func aJobThatEndsWithoutItsEOJIsReported() throws {
        let job = patched(try goodJob(), replacing: "@PJL EOJ NAME=", with: "@PJL XXX NAME=")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-eoj"))
    }

    @Test func anEOJNamingADifferentJobIsReported() throws {
        var options = JobOptions()
        options.jobName = "first"
        let job = patched(try goodJob(options: options), replacing: "EOJ NAME=\"first\"", with: "EOJ NAME=\"other\"")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-eoj"))
    }

    @Test func aMissingLeadingResynchronisationIsReported() throws {
        let job = Array(try goodJob().drop(while: { $0 == 0 }))
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("framing"))
    }

    @Test func aCancelledJobIsReportedAsUnfinished() throws {
        // endJob mid-page closes the raster but sends no form feed: the sheet never ejects.
        let findings = BrotherMonoValidator.check(job: try goodJob(abandonLastPage: true))
        #expect(rules(findings).contains("page"))
    }
}

// MARK: - The page header

@Suite struct BrotherMonoValidatorPageHeaderTests {
    @Test func aPJLVariableWithTheColourModelsSpellingIsReported() throws {
        // The colour models write `@PJL SET X=Y`; this family wants spaces around the `=`.
        let job = patched(try goodJob(), replacing: "@PJL SET ECONOMODE = OFF", with: "@PJL SET ECONOMODE=OFF\n@PJL")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-line"))
    }

    @Test func anIllegalValueForAKnownVariableIsReported() throws {
        let job = patched(try goodJob(), replacing: "@PJL SET SOURCETRAY = AUTO", with: "@PJL SET SOURCETRAY = TRAY1")
        let findings = BrotherMonoValidator.check(job: job)
        #expect(rules(findings).contains("pjl-variable"))
        #expect(findings.first { $0.rule == "pjl-variable" }?.message.contains("T1") == true)
    }

    @Test func anUnknownPaperNameIsReported() throws {
        let job = patched(try goodJob(), replacing: "@PJL SET PAPER = LETTER", with: "@PJL SET PAPER = LETTER2")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-variable"))
    }

    @Test func aMissingSettingIsReported() throws {
        let job = patched(try goodJob(), replacing: "@PJL SET RESOLUTION = 600\n", with: "")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-variable"))
    }

    @Test func enteringTheWrongLanguageIsReported() throws {
        let job = patched(try goodJob(), replacing: "ENTER LANGUAGE = PCL\n", with: "ENTER LANGUAGE = PCLXL\n")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-enter-language"))
    }

    @Test func aMissingPrinterResetIsReported() throws {
        let job = patched(try goodJob(), replacing: "\u{1B}E\u{1B}&l1X", with: "\u{1B}&l1X")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pcl-reset"))
    }

    @Test func askingThePrinterForCopiesIsReported() throws {
        // Copies are produced upstream as repeated pages; asking the printer too would double them.
        let job = patched(try goodJob(), replacing: "\u{1B}&l1X", with: "\u{1B}&l3X")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pcl-copies"))
    }
}

// MARK: - Raster blocks

@Suite struct BrotherMonoValidatorBlockTests {
    @Test func aBlockLengthThatDisagreesWithItsLinesIsReported() throws {
        let job = try goodJob(height: 8)
        let stream = BrotherMonoReader.preamble(of: job)
        let blockStart = try #require(job.firstRange(of: Array("\u{1B}*b1030m".utf8))).upperBound
        #expect(!stream.isEmpty)

        // The block length is the decimal number right after the raster start.
        var end = blockStart
        while job[end] != UInt8(ascii: "w") { end += 1 }
        let declared = Int(String(decoding: job[blockStart..<end], as: UTF8.self)) ?? 0
        var patchedJob = job
        patchedJob.replaceSubrange(blockStart..<end, with: Array("\(declared + 1)".utf8))

        #expect(rules(BrotherMonoValidator.check(job: patchedJob)).contains("block"))
    }

    @Test func aNonZeroByteAfterTheBlockLengthIsReported() throws {
        let job = try goodJob(height: 8)
        let blockStart = try #require(job.firstRange(of: Array("\u{1B}*b1030m".utf8))).upperBound
        var end = blockStart
        while job[end] != UInt8(ascii: "w") { end += 1 }

        var patchedJob = job
        patchedJob[end + 1] = 1
        #expect(rules(BrotherMonoValidator.check(job: patchedJob)).contains("block"))
    }

    @Test func aPageThatNeverClosesItsRasterIsReported() throws {
        let job = patched(try goodJob(), replacing: "1030M", with: "1031M")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("block"))
    }

    @Test func aMissingFormFeedIsReported() throws {
        let job = patched(try goodJob(), replacing: [0x31, 0x30, 0x33, 0x30, 0x4D, 0x0C], with: [0x31, 0x30, 0x33, 0x30, 0x4D])
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("page"))
    }

    @Test func somethingThatIsNotAMonoJobIsReportedRatherThanCrashing() {
        #expect(BrotherMonoValidator.check(job: Array("not a print job at all".utf8)).hasErrors)
        #expect(BrotherMonoValidator.check(job: []).hasErrors)
    }
}
