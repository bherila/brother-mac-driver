import Foundation
import Testing

@testable import BrotherPDL

// The mono row-width check against what the macOS rasteriser was recorded producing
// (bherila/brother-mac-driver#27).
//
// `Tests/Fixtures/mono-raster-headers.tsv` is written by `scripts/capture-mono-headers.sh`, which
// reads the raster header with a reader that shares no code with the driver, and CI re-captures it
// on every run and fails if it no longer matches. So the expectations here come from the
// rasteriser, not from `bytesPerRow` — the point being that the helper cannot agree with itself
// into passing.

/// One row of the fixture, by column name.
private struct CapturedHeader {
    let fields: [String: String]
    subscript(_ column: String) -> String { fields[column] ?? "" }
    var label: String { "\(self["page_size"]) at \(self["resolution"])" }
}

private func capturedHeaders() throws -> [CapturedHeader] {
    // Resolved through symlinks so a scratch package that links the test directory in (see
    // AGENTS.md) still finds the repository's fixture.
    let fixture = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mono-raster-headers.tsv")
    let lines = try String(contentsOf: fixture, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.hasPrefix("#") }
    guard let header = lines.first else { return [] }
    let columns = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    return lines.dropFirst().map { line in
        let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return CapturedHeader(fields: Dictionary(uniqueKeysWithValues: zip(columns, values)))
    }
}

@Suite struct MonoRasterHeaderFixtureTests {
    @Test func everyCapturedRowIsTheWidthTheValidatorExpects() throws {
        let rows = try capturedHeaders()
        #expect(!rows.isEmpty)
        for row in rows {
            let expected = BrotherMonoValidator.bytesPerRow(
                paper: row["pjl_PAPER"], resolution: row["pjl_RESOLUTION"], ras1200Mode: row["pjl_RAS1200MODE"])
            #expect(expected == Int(row["cupsBytesPerLine"]), "\(row.label)")
        }
    }

    @Test func theFixtureCoversEveryPaperTheModelOffersAtBothResolutions() throws {
        // A paper added to the model without being captured would otherwise be checked by
        // arithmetic nothing has confirmed — the situation this fixture exists to end.
        let rows = try capturedHeaders()
        let offered = Set(try #require(PrinterModel.named("HL-2140 series")).mediaSizes.map(\.ppdName))
        for resolution in ["600dpi", "300dpi"] {
            let captured = Set(rows.filter { $0["resolution"] == resolution }.map { $0["page_size"] })
            #expect(captured == offered, "\(resolution)")
        }
    }

    @Test func eachRowIsTheResolutionAndFormatItClaims() throws {
        // The capture script refuses to record a row whose raster is not what was asked for; this
        // keeps a hand-edited fixture honest too.
        for row in try capturedHeaders() {
            let dpi = row["resolution"].replacingOccurrences(of: "dpi", with: "")
            #expect(row["HWResolution"] == "\(dpi),\(dpi)", "\(row.label)")
            #expect(row["pjl_RESOLUTION"] == dpi, "\(row.label)")
            #expect(row["cupsBitsPerPixel"] == "1", "\(row.label)")
            #expect(row["cupsColorSpace"] == "3", "\(row.label)")
        }
    }
}
