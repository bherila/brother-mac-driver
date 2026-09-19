import BrotherPDL
import Foundation

// Developer tool for inspecting and generating printer data streams.
// Subcommands (dump, render, testpage, usb-probe) arrive with the PDL backends.

let usage = """
    usage: pxltool <command> [arguments]

    No commands are implemented yet.
    """

FileHandle.standardError.write(Data((usage + "\n").utf8))
exit(CommandLine.arguments.count > 1 ? 64 : 0)
