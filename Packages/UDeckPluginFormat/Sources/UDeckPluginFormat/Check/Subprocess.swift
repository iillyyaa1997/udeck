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

/// Runs a program to its end, with an environment it is given and nothing
/// else, and answers what it printed.
///
/// `posix_spawn` rather than Foundation's `Process`, which lives in the half of
/// Foundation the Linux build leaves out (by memory — the Linux job is where
/// that would show). Its input and output go through files, not pipes: a git
/// answer can be megabytes, and a pipe nobody reads yet fills at sixty-four
/// kilobytes and stops both sides.
enum Subprocess {
    struct Result {
        /// The exit status, or -1 when a signal ended it.
        var status: Int32
        var output: [UInt8]
        var errors: [UInt8]
    }

    /// Runs `arguments[0]`, found on the `PATH` of `environment`.
    static func run(_ arguments: [String], environment: [String: String], input: [UInt8] = []) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("udeck-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputFile = scratch.appendingPathComponent("in").path
        let outputFile = scratch.appendingPathComponent("out").path
        let errorFile = scratch.appendingPathComponent("err").path
        try Data(input).write(to: URL(fileURLWithPath: inputFile))

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, inputFile, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputFile, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, errorFile, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        // `env` finds the program on the PATH it is handed, which is the one
        // in `environment` — not whatever this process happened to inherit.
        let argv: [UnsafeMutablePointer<CChar>?] = (["/usr/bin/env"] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }

        var pid = pid_t()
        let spawned = posix_spawn(&pid, "/usr/bin/env", &actions, nil, argv, envp)
        guard spawned == 0 else {
            throw CheckFailure("could not start \(arguments.first ?? "a program"): \(String(cString: strerror(spawned)))")
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw CheckFailure("lost \(arguments.first ?? "a program") while it ran") }
        }
        // The shell's own arithmetic, which Swift has no macro for: the low
        // seven bits are a signal, the next eight the exit status.
        let exited = status & 0x7F == 0
        return Result(status: exited ? (status >> 8) & 0xFF : -1,
                      output: Array(try Data(contentsOf: URL(fileURLWithPath: outputFile))),
                      errors: Array(try Data(contentsOf: URL(fileURLWithPath: errorFile))))
    }
}
