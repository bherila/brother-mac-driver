import Foundation

// Developer tool for inspecting printer data streams. All logic lives in `PxlTool`
// so that nothing here needs mutable global state under strict concurrency.
exit(PxlTool.run(Array(CommandLine.arguments.dropFirst())))
