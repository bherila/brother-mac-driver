import BrotherPDL
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

extension PxlTool {
    /// `pxltool usb-send <file> [--listen SECONDS]`
    ///
    /// Sends a ready-made print job straight to a Brother printer over USB, with no print queue
    /// involved, then prints whatever the printer says back. For bring-up: it isolates "does the
    /// printer accept these bytes" from everything macOS does around them, and PCL XL reports its
    /// errors on exactly this back-channel.
    ///
    /// It will only talk to a Brother device, and only when exactly one is connected, so a job can
    /// never land on some other printer that happens to be plugged in.
    static func usbSend(_ arguments: [String]) throws {
        var options = Options()
        try options.parse(arguments, allowed: ["--listen"])
        guard let path = options.path, path != "-" else {
            throw ToolError.message("usage: pxltool usb-send <job-file> [--listen SECONDS]")
        }
        let listenSeconds = try options.integer("--listen") ?? 10
        let job = try readInput(path)
        guard !job.isEmpty else { throw ToolError.message("'\(path)' is empty") }

        let (interface, name) = try openTheBrotherPrinter()
        defer { interface.destroy() }

        let channels = rawChannels(of: interface)
        guard let channel = channels.first(where: { $0.bulkOut != nil && $0.bulkIn != nil }) ?? channels.first(where: { $0.bulkOut != nil }),
            let outAddress = channel.bulkOut
        else {
            throw ToolError.message("\(name) has no raw print channel")
        }
        if channel.alternateSetting != Int(interface.interfaceDescriptor.pointee.bAlternateSetting) {
            try interface.selectAlternateSetting(channel.alternateSetting)
        }
        let out = try interface.copyPipe(withAddress: outAddress)
        let back = try channel.bulkIn.map { try interface.copyPipe(withAddress: $0) }
        write("sending \(job.count) bytes to \(name) (\(channel.summary))", to: FileHandle.standardError)

        var heard = Data()
        var offset = 0
        var stalledSince: Date?
        var chunks = 0
        while offset < job.count {
            let length = min(1 << 16, job.count - offset)
            let chunk = NSMutableData(data: Data(job[offset..<offset + length]))
            var sent = 0
            do {
                try out.__sendIORequest(with: chunk, bytesTransferred: &sent, completionTimeout: 10)
                stalledSince = nil
            } catch let error as NSError where isTimeout(error) {
                // A printer that is busy printing stops taking data for a while; that is not a failure
                // until it has gone on for minutes.
                let since = stalledSince ?? Date()
                stalledSince = since
                if Date().timeIntervalSince(since) > 300 {
                    throw ToolError.message("the printer accepted no data for five minutes; gave up after \(offset + sent) of \(job.count) bytes")
                }
            }
            offset += sent
            chunks += 1
            // Drain the back-channel now and then: some printers stop accepting data when their own
            // messages are not being read.
            if let back, chunks.isMultiple(of: 16) {
                heard.append(try read(back, timeout: 0.05))
            }
        }
        write("sent; listening for \(listenSeconds) s", to: FileHandle.standardError)

        if let back {
            let deadline = Date().addingTimeInterval(TimeInterval(listenSeconds))
            while Date() < deadline {
                heard.append(try read(back, timeout: 1))
            }
        }
        let text = String(decoding: heard, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{0C}", with: "\n")
        write(
            heard.isEmpty
                ? (back == nil ? "(one-way channel: the printer cannot reply)" : "(the printer said nothing)")
                : "the printer said:\n" + DeviceID.redactingSerial(text),
            to: FileHandle.standardOutput)
    }

    /// One read from the back-channel; a timeout is simply "nothing to say right now".
    private static func read(_ pipe: IOUSBHostPipe, timeout: TimeInterval) throws -> Data {
        guard let buffer = NSMutableData(length: 4096) else { return Data() }
        var received = 0
        do {
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: timeout)
        } catch let error as NSError where isTimeout(error) {
            return Data()
        }
        return (buffer as Data).prefix(received)
    }

    /// The single connected Brother printer's raw interface, or an error naming what was found.
    private static func openTheBrotherPrinter() throws -> (IOUSBHostInterface, String) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            throw ToolError.message("cannot enumerate USB interfaces")
        }
        defer { IOObjectRelease(iterator) }

        var brother: [(service: io_service_t, name: String)] = []
        var others: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            func number(_ key: String) -> Int? { (property(key) as? NSNumber)?.intValue }
            let name = property("USB Product Name") as? String ?? property("kUSBProductString") as? String ?? "unknown"
            if number("bInterfaceClass") == 7, number("bInterfaceProtocol") != 4 {
                if number("idVendor") == brotherVendorID {
                    brother.append((service, name))
                    continue
                }
                others.append(name)
            }
            IOObjectRelease(service)
        }
        defer { brother.forEach { IOObjectRelease($0.service) } }

        guard brother.count == 1 else {
            let seen = others.isEmpty ? "" : " (other USB printers, which this command will not send to: \(others.joined(separator: ", ")))"
            throw ToolError.message(
                brother.isEmpty
                    ? "no Brother USB printer is connected\(seen)"
                    : "\(brother.count) Brother printers are connected; disconnect all but the one to test")
        }
        do {
            return (try IOUSBHostInterface(__ioService: brother[0].service, options: [], queue: nil, interestHandler: nil), brother[0].name)
        } catch {
            throw ToolError.message("could not open \(brother[0].name): \(error.localizedDescription) (is a print job running? pause its queue first)")
        }
    }

    /// `pxltool redact`: copies stdin to stdout with serial-number fields blanked, for log collection.
    static func redact(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw ToolError.message("usage: pxltool redact < input > output") }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        FileHandle.standardOutput.write(Data(DeviceID.redactingSerial(input).utf8))
    }
}
