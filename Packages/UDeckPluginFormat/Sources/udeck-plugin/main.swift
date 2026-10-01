// `udeck-plugin`, started: everything it does is `Command`, which tests run
// without starting anything.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import UDeckPluginCommand

// `@Sendable`, so that neither closure belongs to the main actor, as anything
// written at the top of this file otherwise does: `run` calls them from
// wherever its work goes on, and the runtime says so when a closure of the
// main actor is called anywhere else.
let status = await Command.run(
    Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    output: { @Sendable line in print(line) },
    errors: { @Sendable message in
        let bytes = Array((message + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    }
)
exit(status)
