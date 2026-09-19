import Testing

@testable import BrotherPDL

@Suite struct DeviceIDTests {
    @Test func colourModelWithPCLXL() {
        let id = DeviceID("MFG:Brother;CMD:PJL,PCL,PCLXL,URF;MDL:MFC-9330CDW;CLS:PRINTER;CID:Brother Laser Type1;")
        #expect(id.model == "MFC-9330CDW")
        #expect(id.languages == ["PJL", "PCL", "PCLXL", "URF"])
        #expect(id.support == .supported(PrinterModel.named("MFC-9330CDW")!))
        #expect(id.summary.contains("supported by this driver (pclxl backend)"))
    }

    @Test func monoModelIsSupportedThroughItsOwnBackend() {
        let id = DeviceID("MFG:Brother;CMD:PJL,HBP;MDL:HL-2140 series;CLS:PRINTER;")
        #expect(id.support == .supported(PrinterModel.named("HL-2140")!))
        #expect(id.summary == "HL-2140 series reports languages: PJL, HBP - supported by this driver (mono backend)")
    }

    @Test func unknownModelThatSpeaksPCLXL() {
        let id = DeviceID("MFG:Brother;CMD:PJL,PCLXL;MDL:HL-9999CDW;")
        #expect(id.support == .speaksPCLXL)
    }

    @Test func hostBasedOnlyModel() {
        let id = DeviceID("MFG:Brother;CMD:PJL,XL2HB;MDL:HL-3140CW series;CLS:PRINTER;")
        #expect(id.support == .unsupported)
        #expect(id.summary == "HL-3140CW series reports languages: PJL, XL2HB - not supported by this driver")
    }

    @Test func longFieldNamesAndSpaces() {
        let id = DeviceID("MANUFACTURER:Zebra Technologies ;COMMAND SET:EPL;MODEL:ZTC GC420d (EPL);CLASS:PRINTER;")
        #expect(id.model == "ZTC GC420d (EPL)")
        #expect(id.languages == ["EPL"])
        #expect(id.support == .unsupported)
    }

    @Test func emptyOrMalformed() {
        #expect(DeviceID("").model == nil)
        #expect(DeviceID(";;nonsense;").languages.isEmpty)
        #expect(DeviceID("").summary == "unknown model reports no languages - not supported by this driver")
    }

    @Test(arguments: [
        ("MFG:Brother;MDL:MFC-9330CDW;SN:U63481A5J123456;", "MFG:Brother;MDL:MFC-9330CDW;SN:<redacted>;"),
        ("usb://Brother/MFC-9330CDW?serial=U63481A5J123456", "usb://Brother/MFC-9330CDW?serial=<redacted>"),
        ("MODEL:X;SERN:ABC123;CLASS:PRINTER;", "MODEL:X;SERN:<redacted>;CLASS:PRINTER;"),
        ("@PJL INFO ID\n\"Brother HL-2140 series:84U-F75:Ver.1.10\"\nSERIALNUMBER=\"X1 Y2\"\nNEXT", "@PJL INFO ID\n\"Brother HL-2140 series:84U-F75:Ver.1.10\"\nSERIALNUMBER=<redacted>\nNEXT"),
        ("SN:\"unterminated", "SN:<redacted>"),
        ("CMD:PJL,HBP;MDL:HL-2140 series;", "CMD:PJL,HBP;MDL:HL-2140 series;"),
        ("DESCRIPTION:Brother MFC;", "DESCRIPTION:Brother MFC;"),
    ])
    func serialRedaction(text: String, expected: String) {
        #expect(DeviceID.redactingSerial(text) == expected)
    }
}
