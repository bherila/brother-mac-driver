import BrotherPDL
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

extension PxlTool {
    static let brotherVendorID = 0x04F9

    /// `pxltool usb-probe [--pjl yes] [--show-serial yes]`
    ///
    /// Lists USB printers and what each says about itself (its IEEE-1284 device ID, which names the
    /// model and the languages it accepts). Reading the ID is a standard, side-effect-free class
    /// request. With `--pjl yes`, Brother printers are also sent PJL status queries — which print
    /// nothing — and the replies are shown.
    static func usbProbe(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: ["--pjl", "--show-serial"])
        guard options.path == nil else { throw ToolError.message("usage: pxltool usb-probe [--pjl yes] [--show-serial yes]") }
        let queryPJL = options.values["--pjl"] == "yes"
        let showSerial = options.values["--show-serial"] == "yes"

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            throw ToolError.message("cannot enumerate USB interfaces")
        }
        defer { IOObjectRelease(iterator) }

        var found = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            func number(_ key: String) -> Int? { (property(key) as? NSNumber)?.intValue }
            // Interface class 7 is "printer".
            guard number("bInterfaceClass") == 7 else { continue }
            found += 1

            let vendor = number("idVendor") ?? 0
            let name = property("USB Product Name") as? String ?? property("kUSBProductString") as? String ?? "unknown"
            write(
                "\(name): vendor 0x\(String(vendor, radix: 16)) product 0x\(String(number("idProduct") ?? 0, radix: 16)) "
                    + "interface \(number("bInterfaceNumber") ?? 0)",
                to: FileHandle.standardOutput)

            do {
                let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
                defer { interface.destroy() }

                let deviceID = try readDeviceID(interface, interfaceNumber: UInt16(number("bInterfaceNumber") ?? 0))
                write("  device id: \(showSerial ? deviceID : DeviceID.redactingSerial(deviceID))", to: FileHandle.standardOutput)
                write("  \(DeviceID(deviceID).summary)", to: FileHandle.standardOutput)

                if queryPJL {
                    if vendor == brotherVendorID {
                        let reply = try pjlQuery(interface)
                        write("  PJL replies:\n" + (showSerial ? reply : DeviceID.redactingSerial(reply)).split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"), to: FileHandle.standardOutput)
                    } else {
                        write("  (not a Brother device; PJL queries skipped)", to: FileHandle.standardOutput)
                    }
                }
            } catch {
                write("  could not open the interface: \(error.localizedDescription) (is a print job running?)", to: FileHandle.standardOutput)
            }
        }
        if found == 0 {
            write("no USB printers found", to: FileHandle.standardOutput)
        }
    }

    /// GET_DEVICE_ID: class request 0 on the interface; the reply is a big-endian length and the ID string.
    private static func readDeviceID(_ interface: IOUSBHostInterface, interfaceNumber: UInt16) throws -> String {
        let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0, wValue: 0, wIndex: interfaceNumber << 8, wLength: 1023)
        guard let data = NSMutableData(length: 1023) else { return "" }
        var transferred = 0
        try interface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 3)
        let bytes = [UInt8](data as Data).prefix(transferred)
        guard bytes.count >= 2 else { return "" }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        return String(decoding: bytes.dropFirst(2).prefix(max(0, length - 2)), as: UTF8.self)
    }

    /// Sends PJL INFO queries on the bulk OUT endpoint and collects what comes back on bulk IN.
    private static func pjlQuery(_ interface: IOUSBHostInterface) throws -> String {
        var out: IOUSBHostPipe?
        var back: IOUSBHostPipe?
        var endpoint = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, nil)
        while let descriptor = endpoint {
            // bmAttributes low two bits: 2 = bulk. Address bit 7: 1 = device-to-host.
            if descriptor.pointee.bmAttributes & 3 == 2 {
                let address = Int(descriptor.pointee.bEndpointAddress)
                if address & 0x80 != 0 {
                    if back == nil { back = try interface.copyPipe(withAddress: address) }
                } else if out == nil {
                    out = try interface.copyPipe(withAddress: address)
                }
            }
            endpoint = IOUSBGetNextEndpointDescriptor(
                interface.configurationDescriptor, interface.interfaceDescriptor,
                UnsafeRawPointer(descriptor).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }
        guard let out else { throw ToolError.message("printer has no bulk OUT endpoint") }
        guard let back else { return "(printer has no bulk IN endpoint: it cannot reply)" }

        let query = "\u{1B}%-12345X@PJL\r\n@PJL INFO ID\r\n@PJL INFO CONFIG\r\n@PJL INFO VARIABLES\r\n\u{1B}%-12345X"
        var sent = 0
        try out.__sendIORequest(with: NSMutableData(data: Data(query.utf8)), bytesTransferred: &sent, completionTimeout: 5)

        var reply = Data()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            guard let buffer = NSMutableData(length: 4096) else { break }
            var received = 0
            // A timeout just means the printer has nothing more to say.
            guard (try? back.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: 1.5)) != nil, received > 0 else {
                if !reply.isEmpty { break }
                continue
            }
            reply.append((buffer as Data).prefix(received))
        }
        return reply.isEmpty ? "(no reply)" : String(decoding: reply, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{0C}", with: "")
    }
}
