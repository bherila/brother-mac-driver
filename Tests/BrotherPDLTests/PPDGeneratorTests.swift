import Testing

@testable import BrotherPDL

/// Structural checks. Conformance to the PPD specification is checked by `cupstestppd` in scripts/e2e-test.sh.
@Suite struct PPDGeneratorTests {
    let model = PrinterModel.named("MFC-9330CDW")!
    var ppd: String { PPDGenerator.ppd(for: model) }
    var lines: [Substring] { ppd.split(separator: "\n", omittingEmptySubsequences: false) }

    /// Choice keywords of a `*Keyword choice/Text: "code"` option, in order.
    func choices(_ keyword: String) -> [String] {
        lines.filter { $0.hasPrefix("*\(keyword) ") }
            .compactMap { $0.dropFirst(keyword.count + 2).split(separator: "/").first.map(String.init) }
    }

    func value(_ keyword: String) -> String? {
        lines.first { $0.hasPrefix("*\(keyword): ") }.map { String($0.dropFirst(keyword.count + 3)) }
    }

    @Test func identifiesTheModelForAutomaticMatching() {
        #expect(value("1284DeviceID") == "\"MFG:Brother;MDL:MFC-9330CDW;\"")
        #expect(value("ModelName") == "\"Brother MFC-9330CDW\"")
        #expect(value("PCFileName") == "\"BR330CDW.PPD\"")
        #expect(value("BRBackend") == "\"pclxl\"")
    }

    @Test func routesRasterToTheInstalledFilter() {
        #expect(value("cupsFilter") == "\"application/vnd.cups-raster 50 /Library/Printers/BrotherOSS/filter/rastertobrother\"")
    }

    @Test func pcFileNameIsEightDotThree() {
        let name = PPDGenerator.pcFileName(model)
        #expect(name.count <= 12)
        #expect(name == name.uppercased())
        #expect(name.hasSuffix(".PPD"))
    }

    @Test func everyMediaSizeAppearsInAllFourSections() {
        let expected = MediaSize.all.map(\.ppdName)
        for keyword in ["PageSize", "PageRegion", "ImageableArea", "PaperDimension"] {
            #expect(choices(keyword) == expected, "\(keyword)")
        }
    }

    @Test func imageableAreaMatchesTheMediaTable() {
        #expect(lines.contains("*ImageableArea Letter/US Letter: \"12 12 600 780\""))
        #expect(lines.contains("*PaperDimension A4/A4: \"595 842\""))
    }

    /// The keywords the filter looks up (FilterSupport.swift) must exist with the choices it compares against.
    @Test func optionKeywordsMatchWhatTheFilterReads() {
        #expect(choices("ColorModel") == ["Auto", "RGB", "Gray"])
        #expect(choices("Duplex") == ["None", "DuplexNoTumble", "DuplexTumble"])
        #expect(choices("InputSlot") == ["Auto", "Tray1", "Manual"])
        #expect(choices("BRTonerSaveMode") == ["OFF", "ON"])
        #expect(choices("BRCompression") == ["RLE", "DeltaRow"])
        #expect(choices("BRPJL") == ["ON", "OFF"])
        #expect(choices("BRErrorPage") == ["OFF", "ON"])
    }

    @Test func everyDefaultNamesAnExistingChoice() {
        for line in lines where line.hasPrefix("*Default") {
            let parts = line.dropFirst("*Default".count).split(separator: ":", maxSplits: 1)
            let keyword = String(parts[0])
            let choice = parts[1].trimmingPrefix(" ")
            guard !["ColorSpace", "Font"].contains(keyword) else { continue }
            #expect(choices(keyword).contains(String(choice)), "*Default\(keyword): \(choice)")
        }
    }

    @Test func rasterIsRequestedAs8BitSRGBOrGrayAt600dpi() {
        func code(_ prefix: String) -> String {
            lines.first { $0.hasPrefix(prefix) }.map(String.init) ?? ""
        }
        #expect(code("*ColorModel Gray/").hasSuffix("\"<</cupsColorSpace 18/cupsColorOrder 0/cupsBitsPerColor 8>>setpagedevice\""))
        #expect(code("*ColorModel Auto/").hasSuffix("\"<</cupsColorSpace 19/cupsColorOrder 0/cupsBitsPerColor 8>>setpagedevice\""))
        #expect(code("*ColorModel RGB/").hasSuffix("\"<</cupsColorSpace 19/cupsColorOrder 0/cupsBitsPerColor 8>>setpagedevice\""))
        #expect(code("*Resolution 600dpi/").hasSuffix("\"<</HWResolution[600 600]>>setpagedevice\""))
    }

    @Test func isPlainASCIIWithBalancedUIBlocks() {
        let nonASCII = ppd.unicodeScalars.filter { !$0.isASCII }
        #expect(nonASCII.isEmpty)
        let opened = lines.filter { $0.hasPrefix("*OpenUI ") }.count
        let closed = lines.filter { $0.hasPrefix("*CloseUI: ") }.count
        #expect(opened == closed && opened > 5)
        #expect(ppd.hasPrefix("*PPD-Adobe: \"4.3\"\n"))
    }

    // MARK: Every model

    @Test func everyModelHasAUniqueFileNameShortNameAndDeviceID() {
        let models = PrinterModel.all
        #expect(Set(models.map(\.ppdBaseName)).count == models.count)
        #expect(Set(models.map(PPDGenerator.pcFileName)).count == models.count)
        #expect(Set(models.map(\.name)).count == models.count)
        for model in models {
            let name = PPDGenerator.pcFileName(model)
            #expect(name.count <= 12 && name == name.uppercased(), "\(name)")
            #expect(!model.ppdBaseName.contains(" "))
            #expect(PrinterModel.named(model.name) == model)
        }
    }

    @Test func colourSiblingsShareTheFlagshipsOptions() {
        func options(_ name: String) -> [Substring] {
            PPDGenerator.ppd(for: PrinterModel.named(name)!).split(separator: "\n")
                .filter { $0.hasPrefix("*OpenUI ") || $0.hasPrefix("*Default") || $0.hasPrefix("*cupsFilter") || $0.hasPrefix("*BRBackend") }
        }
        #expect(options("MFC-9340CDW") == options("MFC-9330CDW"))
        #expect(options("HL-3170CDW") == options("MFC-9330CDW"))
    }

    // MARK: Mono models

    var monoLines: [Substring] {
        PPDGenerator.ppd(for: PrinterModel.named("HL-2140")!).split(separator: "\n", omittingEmptySubsequences: false)
    }

    @Test func monoModelIsFoundWithOrWithoutSeries() {
        #expect(PrinterModel.named("HL-2140 series")?.backend == .mono)
        #expect(PrinterModel.named("hl-2140")?.name == "HL-2140 series")
    }

    @Test func monoPPDIdentityAndFileNames() {
        let model = PrinterModel.named("HL-2140")!
        #expect(model.ppdBaseName == "Brother-HL-2140-series")
        #expect(PPDGenerator.pcFileName(model) == "BRHL2140.PPD")
        #expect(monoLines.contains("*1284DeviceID: \"MFG:Brother;MDL:HL-2140 series;\""))
        #expect(monoLines.contains("*BRBackend: \"mono\""))
        #expect(monoLines.contains("*ColorDevice: False"))
    }

    @Test func monoPPDRequestsOneBitBlackAndOffersNoColourOrPCLXLOptions() {
        let resolution = monoLines.first { $0.hasPrefix("*Resolution 600dpi/") }.map(String.init) ?? ""
        #expect(resolution.hasSuffix("\"<</HWResolution[600 600]/cupsColorSpace 3/cupsColorOrder 0/cupsBitsPerColor 1>>setpagedevice\""))
        for keyword in ["ColorModel", "Duplex", "BRCompression", "BRPJL", "BRErrorPage"] {
            let offered = monoLines.contains { $0.hasPrefix("*OpenUI *\(keyword)/") }
            #expect(!offered, "\(keyword)")
        }
    }

    @Test func monoPPDUsesItsOwnMarginsAndSizeList() {
        #expect(monoLines.contains("*ImageableArea Letter/US Letter: \"8 8 604 776\""))
        let sizes = monoLines.filter { $0.hasPrefix("*PageSize ") }.compactMap { $0.dropFirst(10).split(separator: "/").first.map(String.init) }
        #expect(sizes == ["A4", "Letter", "Legal", "Executive", "A5", "A6", "B5", "B6", "EnvDL", "EnvC5", "EnvMonarch"])
    }
}
