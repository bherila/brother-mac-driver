import BrotherPDL
import CCUPS
import CCUPSShim
import CUPSRaster
import Foundation

/// CUPS reads a filter's stderr line by line; the prefix sets the log level (and `PAGE:` does accounting).
enum Log {
    static func debug(_ message: String) { write("DEBUG", message) }
    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }
    /// Page accounting: `PAGE: <page-number> <copies>`.
    static func page(_ number: Int, copies: Int = 1) { write("PAGE", "\(number) \(copies)") }

    private static func write(_ prefix: String, _ message: String) {
        FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
    }
}

struct FilterError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// stdout, which CUPS connects to the backend (USB, socket, …).
enum Stdout {
    static func sink() -> BufferedSink {
        BufferedSink { try writeAll($0) }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Foundation.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                // stdout is normally blocking; if it is not, wait for room instead of spinning.
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, -1)
            } else {
                let reason = written == 0 ? "no progress" : String(cString: strerror(errno))
                throw FilterError("Unable to send data to the printer: \(reason)")
            }
        }
    }
}

/// Job cancellation. CUPS sends SIGTERM; the handler may only set a flag.
enum Cancellation {
    nonisolated(unsafe) private static var flag: sig_atomic_t = 0

    static var isCancelled: Bool { flag != 0 }

    static func install() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in Cancellation.flag = 1 }
    }
}

/// The PPD named by `$PPD`, with defaults and then the job's options marked.
final class MarkedPPD {
    private let ppd: OpaquePointer

    init?(path: String?, jobOptions: String) {
        guard let path, let ppd = brppd_open(path, jobOptions) else { return nil }
        self.ppd = ppd
    }

    deinit {
        brppd_close(ppd)
    }

    /// The marked choice keyword for an option, e.g. `choice("InputSlot") == "Tray1"`.
    func choice(_ option: String) -> String? {
        brppd_marked_choice(ppd, option).map { String(cString: $0) }
    }

    /// The value of a driver-defined attribute, e.g. `*BRBackend: "pclxl"`.
    func attribute(_ name: String) -> String? {
        brppd_attribute(ppd, name).map { String(cString: $0) }
    }
}

extension JobOptions {
    /// Options that come from the PPD's marked choices. Page-level facts (size, duplex) come from the raster header.
    init(ppd: MarkedPPD?, jobTitle: String) {
        self.init()
        jobName = jobTitle
        guard let ppd else { return }

        switch ppd.choice("ColorModel") {
        case "RGB": colorMode = .color
        case "Gray": colorMode = .mono
        default: colorMode = .auto
        }
        switch ppd.choice("InputSlot") {
        case "Tray1": inputSlot = .tray1
        case "Tray2": inputSlot = .tray2
        case "Manual": inputSlot = .manual
        default: inputSlot = .auto
        }
        tonerSave = ppd.choice("BRTonerSaveMode") == "ON"
        compression = ppd.choice("BRCompression") == "DeltaRow" ? .deltaRow : .rle
        brotherPJL = ppd.choice("BRPJL") != "OFF"
        errorPage = ppd.choice("BRErrorPage") == "ON"
    }
}
