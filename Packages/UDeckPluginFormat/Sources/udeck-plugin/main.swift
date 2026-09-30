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

let status = Command.run(
    Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    output: { print($0) },
    errors: { message in
        let bytes = Array((message + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    }
)
exit(status)
