import Testing

@testable import BrotherPDL

@Suite struct MediaTests {
    /// PPD `*PageSize` keywords in the order Brother's GPL PPD lists them.
    static let expectedOrder = [
        "A4", "Letter", "Legal", "Executive", "A5", "A6", "B5", "JISB5", "JISB6",
        "EnvDL", "EnvC5", "Env10", "EnvMonarch", "Br3x5", "FanFoldGermanLegal",
        "EnvPRC5Rotated", "Postcard", "EnvYou4", "EnvChou3",
        "210x270mm", "195x270mm", "184x260mm", "197x273mm",
    ]

    @Test func allMatchesPPDOrder() {
        #expect(MediaSize.all.map(\.ppdName) == Self.expectedOrder)
    }

    @Test func namesAreUnique() {
        let names = MediaSize.all.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: [
        ("Letter", 612.0, 792.0),
        ("A4", 595.0, 842.0),
        ("Legal", 612.0, 1008.0),
    ])
    func dimensionsSpotCheck(ppdName: String, width: Double, height: Double) {
        let size = MediaSize.named(ppdName)
        #expect(size?.widthPoints == width)
        #expect(size?.heightPoints == height)
    }

    /// Brother's raster table (`paperinfij2`), imageable-area width/height in 600-dpi pixels.
    /// `ISOB5` in that file is `B5` in the PPD.
    static let paperinfij2: [String: (width: Int, height: Int)] = [
        "A4": (4760, 6812),
        "Letter": (4900, 6400),
        "Legal": (4900, 8200),
        "Executive": (4148, 6100),
        "A5": (3296, 4760),
        "A6": (2272, 3300),
        "B5": (3956, 5708),
        "JISB5": (4100, 5872),
        "JISB6": (2824, 4100),
        "EnvDL": (2400, 4996),
        "EnvC5": (3624, 5208),
        "Env10": (2272, 5500),
        "EnvMonarch": (2124, 4300),
        "Br3x5": (1600, 2800),
        "FanFoldGermanLegal": (4900, 7600),
        "EnvPRC5Rotated": (5000, 2400),
        "Postcard": (2164, 3288),
        "EnvYou4": (2280, 5348),
        "EnvChou3": (2632, 5348),
        "210x270mm": (4760, 6175),
        "195x270mm": (4408, 6175),
        "184x260mm": (4152, 5942),
        "197x273mm": (4452, 6250),
    ]

    @Test func crossCheckAgainstBrotherRasterTable() {
        for size in MediaSize.all {
            guard let expected = Self.paperinfij2[size.ppdName] else {
                Issue.record("No paperinfij2 entry for \(size.ppdName)")
                continue
            }
            let imageableWidthPoints = size.widthPoints - 2 * size.marginPoints
            let imageableHeightPoints = size.heightPoints - 2 * size.marginPoints
            let computedWidth = imageableWidthPoints * 600 / 72
            let computedHeight = imageableHeightPoints * 600 / 72

            #expect(
                abs(computedWidth - Double(expected.width)) <= 8,
                "\(size.ppdName) width: computed \(computedWidth), paperinfij2 \(expected.width)"
            )
            #expect(
                abs(computedHeight - Double(expected.height)) <= 8,
                "\(size.ppdName) height: computed \(computedHeight), paperinfij2 \(expected.height)"
            )
        }
    }

    @Test func pixelSizeAt600dpi() throws {
        let letter = try #require(MediaSize.named("Letter")).pixelSize(dpi: 600)
        #expect(letter == (5100, 6600))

        let a4 = try #require(MediaSize.named("A4")).pixelSize(dpi: 600)
        #expect(a4 == (4958, 7017))
    }

    @Test func namedHit() {
        #expect(MediaSize.named("Letter")?.displayName == "US Letter")
    }

    @Test func namedMiss() {
        #expect(MediaSize.named("NoSuchSize") == nil)
    }

    @Test func matchingExact() {
        #expect(MediaSize.matching(widthPoints: 612, heightPoints: 792)?.ppdName == "Letter")
    }

    @Test func matchingWithinTolerance() {
        #expect(MediaSize.matching(widthPoints: 611, heightPoints: 793, tolerance: 2)?.ppdName == "Letter")
    }

    @Test func matchingRotated() {
        #expect(MediaSize.matching(widthPoints: 792, heightPoints: 612)?.ppdName == "Letter")
    }

    /// DL (312 × 624) and long-edge DL (624 × 312) are each other's rotation: the orientation given
    /// must decide, not the order of the table.
    @Test func matchingPrefersTheStraightOrientation() {
        #expect(MediaSize.matching(widthPoints: 624, heightPoints: 312)?.ppdName == "EnvPRC5Rotated")
        #expect(MediaSize.matching(widthPoints: 312, heightPoints: 624)?.ppdName == "EnvDL")
        #expect(MediaSize.matching(widthPoints: 623, heightPoints: 313)?.ppdName == "EnvPRC5Rotated")
    }

    @Test func matchingCanRefuseRotation() {
        #expect(MediaSize.matching(widthPoints: 792, heightPoints: 612, allowingRotation: false) == nil)
        #expect(MediaSize.matching(widthPoints: 612, heightPoints: 792, allowingRotation: false)?.ppdName == "Letter")
        #expect(MediaSize.matching(widthPoints: 624, heightPoints: 312, allowingRotation: false)?.ppdName == "EnvPRC5Rotated")
    }

    @Test func matchingMiss() {
        #expect(MediaSize.matching(widthPoints: 100, heightPoints: 100) == nil)
    }

    @Test func pclxlMappingsAreUnique() {
        let codes = MediaSize.all.compactMap(\.pclxl)
        #expect(Set(codes.map(\.rawValue)).count == codes.count)
    }
}
