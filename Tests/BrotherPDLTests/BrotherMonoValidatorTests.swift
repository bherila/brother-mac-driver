import Testing

@testable import BrotherPDL

// As with the PCL XL validator: every check starts from a job the real backend produced and
// breaks one thing in it, so a rule that never fires would show up as a failing test here.

// MARK: - Helpers

/// A job from the real encoder: `pages` pages with a black bar down the left of each.
///
/// The default page is US Letter as the macOS rasteriser delivers it to this backend — 4967
/// pixels across, which is 612 pt less brlaser's 8 pt side margins at 600 dpi. The width has to
/// match the paper the page header names, because the validator now checks exactly that.
private func goodJob(
    pages: Int = 1, width: Int = 4967, height: Int = 200, options: JobOptions = JobOptions(),
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
        // 4967 pixels is 621 bytes per row; the raster states that, the job does not.
        #expect(BrotherMonoValidator.check(job: try goodJob(), bytesPerRow: 621).isEmpty)
        #expect(BrotherMonoValidator.check(job: try goodJob(), bytesPerRow: 300).hasErrors)
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

// MARK: - Findings from the first external review of this file

@Suite struct BrotherMonoValidatorReviewTests {
    @Test func enteringTheLanguageTwiceIsReported() throws {
        // The first ENTER LANGUAGE leaves PJL, so the printer reads the second one as PCL.
        let job = patched(
            try goodJob(), replacing: "@PJL ENTER LANGUAGE = PCL\n",
            with: "@PJL ENTER LANGUAGE = PCL\n@PJL ENTER LANGUAGE = PCL\n")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-enter-language"))
    }

    @Test func pagesMayDifferInWidth() throws {
        // Nothing in the job states the row width, so it is inferred — but from the page being
        // read, not from the first page in the job. A wider second page is not an error.
        var sink = ByteBuffer()
        var backend = BrotherMonoBackend(options: JobOptions())
        // Letter and A4 as this backend receives them: 612 and 595 pt less 16 pt of side margin,
        // at 600 dpi.
        let sizes = [
            (width: 4967, sheet: PageGeometry.Size(width: 612, height: 792)),
            (width: 4825, sheet: PageGeometry.Size(width: 595, height: 842)),
        ]
        try backend.beginJob(to: &sink)
        for size in sizes {
            let geometry = PageGeometry(
                width: size.width, height: 80, dpi: 600, format: .black1, mediaPoints: size.sheet)
            var row = [UInt8](repeating: 0, count: geometry.bytesPerRow)
            for index in 0..<8 { row[index] = 0xFF }
            try backend.beginPage(geometry, to: &sink)
            for _ in 0..<geometry.height {
                try row.withUnsafeBytes { try backend.writeRow($0, to: &sink) }
            }
            try backend.endPage(to: &sink)
        }
        try backend.endJob(to: &sink)

        let findings = BrotherMonoValidator.check(job: sink.bytes)
        #expect(findings.isEmpty, "\(findings)")
    }
}

@Suite struct BrotherMonoValidatorSecondReviewTests {
    @Test func aBlockLengthTooLongToHoldIsReportedRatherThanTrapping() throws {
        // A malformed job can carry any run of digits it likes, and multiplying them out used to
        // overflow and trap — killing the tool whose job is to describe the malformation.
        let job = try goodJob(height: 8)
        let blockStart = try #require(job.firstRange(of: Array("\u{1B}*b1030m".utf8))).upperBound
        var end = blockStart
        while job[end] != UInt8(ascii: "w") { end += 1 }

        var patchedJob = job
        patchedJob.replaceSubrange(blockStart..<end, with: Array(String(repeating: "9", count: 40).utf8))
        #expect(rules(BrotherMonoValidator.check(job: patchedJob)).contains("block"))
    }

    @Test func aCopyCountTooLongToHoldIsReportedRatherThanTrapping() throws {
        let job = patched(
            try goodJob(), replacing: "\u{1B}&l1X", with: "\u{1B}&l\(String(repeating: "9", count: 40))X")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pcl-copies"))
    }
}

@Suite struct BrotherMonoValidatorFourthReviewTests {
    @Test func rowsThatDisagreeWithTheDeclaredPaperAreReported() throws {
        // The header says A4 and the rows are Letter-wide. Both halves are internally consistent,
        // so neither the block framing nor a comparison against the raster would notice — the page
        // simply comes out garbled.
        let job = patched(try goodJob(), replacing: "@PJL SET PAPER = LETTER\n", with: "@PJL SET PAPER = A4\n")
        let findings = BrotherMonoValidator.check(job: job)
        #expect(rules(findings).contains("raster-width"))
        #expect(findings.first { $0.rule == "raster-width" }?.message.contains("604") == true)
    }

    @Test func theWidthImpliedByEachPaperIsTheOneTheRasteriserProduces() {
        // Letter and A4 at 600 dpi, less brlaser's 8 pt side margins: the widths the end-to-end
        // test observes coming out of the macOS rasteriser.
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "600") == 621)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "A4", resolution: "600") == 604)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "300") == 311)
        // An unreadable pair says nothing rather than guessing.
        #expect(BrotherMonoValidator.bytesPerRow(paper: "NOSUCHPAPER", resolution: "600") == nil)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: nil) == nil)
    }

    @Test func aJobNamedAfterPCLXLIsStillReadAsMono() throws {
        // A job title is the user's to choose, and it travels in the PJL header.
        var options = JobOptions()
        options.jobName = ") HP-PCL XL is not what this is"
        let job = try goodJob(options: options)
        #expect(BrotherMonoReader.recognizes(job))
        #expect(BrotherMonoValidator.check(job: job).isEmpty)
    }
}

// MARK: - Findings from the fifth external review of this file

@Suite struct BrotherMonoValidatorFifthReviewTests {
    @Test func aPCLXLJobIsNotClaimedAsMonoBecauseOfHowItsHeaderIsSpaced() {
        // The PCL XL parser skips NUL, space and the whole 0x09–0x0D run before the binding, so a
        // job spaced that way is a PCL XL job. Reading the same bytes as mono would hand them to
        // the wrong validator, and the raster start marker turns up in binary image data often
        // enough that its presence cannot be the deciding test.
        var job = PCLXLReader.uel
        job += Array("@PJL ENTER LANGUAGE=PCLXL\n".utf8)
        job += [0x00, 0x20, 0x09]
        job += Array(") HP-PCL XL;2;0;fifth review\n".utf8)
        job += Array("\u{1B}*b1030m".utf8)
        job += PCLXLReader.uel
        #expect(!BrotherMonoReader.recognizes(job))
    }

    @Test func aRealMonoJobIsStillRecognised() throws {
        #expect(BrotherMonoReader.recognizes(try goodJob()))
    }

    @Test func aResolutionTooLargeToMultiplyOutSaysNothingRatherThanTrapping() {
        // The page header is whatever the job says it is. 1200 is the highest this family reaches,
        // through RAS1200MODE; past that the figure is not a resolution at all.
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "1200") == 1242)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "1201") == nil)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "0") == nil)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "9223372036854775807") == nil)
    }

    @Test func aJobNameThatIsNotPrintableASCIIIsReported() throws {
        // The encoder cannot emit this; a capture read back from a queue can hold anything, and a
        // control byte in the middle of a PJL line is not a name the printer will read back out.
        var options = JobOptions()
        options.jobName = "review"
        var job = try goodJob(options: options)
        job = patched(job, replacing: "JOB NAME=\"review\"", with: "JOB NAME=\"rev\u{01}ew\"")
        job = patched(job, replacing: "EOJ NAME=\"review\"", with: "EOJ NAME=\"rev\u{01}ew\"")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("pjl-job"))
    }

    @Test func aLineTooWideForTheDeclaredPaperIsReportedFromTheFirstBlankLine() throws {
        // A block whose first line is blank never reveals the encoded row width, so before this
        // the rest of the block was unchecked. The paper and resolution in the page header say how
        // wide a Letter row is at 600 dpi — 621 bytes — which is enough to judge the line.
        //
        // The block: a blank line (0xFF), then one substitute whose gap field escapes to
        // 15 + 255 + 255 + 200 = 725 and writes one byte at the end of it.
        let data: [UInt8] = [0xFF, 0x01, 0x78, 0xFF, 0xFF, 0xC8, 0x00]
        var block = Array("\(data.count + 2)w".utf8)
        block += [0x00, UInt8(2)]
        block += data

        let job = try goodJob(height: 8)
        let start = try #require(job.firstRange(of: Array("\u{1B}*b1030m".utf8))).upperBound
        let end = try #require(job[start...].firstRange(of: Array("1030M".utf8))).lowerBound
        var patchedJob = job
        patchedJob.replaceSubrange(start..<end, with: block)

        let findings = BrotherMonoValidator.check(job: patchedJob)
        #expect(rules(findings).contains("line"), "\(findings)")
        #expect(findings.first { $0.rule == "line" }?.message.contains("into a row of 621") == true, "\(findings)")
    }
}

// MARK: - Findings from the owner's review

@Suite struct BrotherMonoValidatorRasterModeTests {
    @Test func aRAS1200ModeHeaderIsA1200DPIRaster() {
        // How brlaser asks for 1200 dpi: the mode goes TRUE and RESOLUTION stays at 600. Reading
        // the resolution alone halves the width, and the row check then calls a correct job
        // garbled — which is a validator that rejects the very encoder it was written from.
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "600") == 621)
        #expect(
            BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "600", ras1200Mode: "TRUE") == 1242)
        #expect(
            BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "600", ras1200Mode: "FALSE") == 621)
        #expect(BrotherMonoValidator.bytesPerRow(paper: "A4", resolution: "600", ras1200Mode: "TRUE") == 1207)
    }

    @Test func anUnreadableRasterModeLeavesTheWidthUnchecked() {
        // A value this driver does not know may mean the raster is scaled some other way. Saying
        // nothing is right; guessing 600 dpi is how the previous version got it wrong.
        #expect(BrotherMonoValidator.bytesPerRow(paper: "LETTER", resolution: "600", ras1200Mode: "MAYBE") == nil)
    }

    @Test func aBrlaserStyle1200DPIJobIsNotReportedAsTheWrongWidth() throws {
        // The whole header, end to end, through the validator: the rows are 1242 bytes because
        // the mode says 1200 dpi, and nothing should object to them.
        let job = patched(
            try goodJob(width: 9933), replacing: "@PJL SET RAS1200MODE = FALSE\n",
            with: "@PJL SET RAS1200MODE = TRUE\n")
        let findings = BrotherMonoValidator.check(job: job)
        #expect(!rules(findings).contains("raster-width"), "\(findings)")
        #expect(!rules(findings).contains("line"), "\(findings)")
    }

    @Test func aRAS1200ModeJobStillHasToBeTheRightWidth() throws {
        // The control: 600 dpi rows under a header claiming 1200 dpi are still reported.
        let job = patched(
            try goodJob(), replacing: "@PJL SET RAS1200MODE = FALSE\n", with: "@PJL SET RAS1200MODE = TRUE\n")
        #expect(rules(BrotherMonoValidator.check(job: job)).contains("raster-width"))
    }
}
