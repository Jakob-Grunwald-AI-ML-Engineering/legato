#if os(macOS)
import Foundation

await BenchCLI.main(arguments: Array(CommandLine.arguments.dropFirst()))
#else
print("legato-bench runs on macOS only")
#endif
