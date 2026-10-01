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
/// kilobytes and stops both sides. The files have no names: each is unlinked
/// the moment it is made and lives on in its descriptors, so a run that is
/// stopped — a signal, a CI job's timeout — leaves nothing behind in the
/// temporary folder, where folders of them used to pile up.
enum Subprocess {
    struct Result {
        /// The exit status, or -1 when a signal ended it.
        var status: Int32
        var output: [UInt8]
        var errors: [UInt8]
    }

    /// Runs `arguments[0]`, found on the `PATH` of `environment`, with its
    /// files made in `folder`.
    static func run(_ arguments: [String], environment: [String: String], input: [UInt8] = [],
                    in folder: String = FileManager.default.temporaryDirectory.path) throws -> Result {
        var files: [Int32] = []
        defer { for file in files { close(file) } }
        // Standard input, output and error, in that order: each one made takes
        // the lowest descriptor free, so when this process runs with one of
        // 0, 1 or 2 closed, every one of them is copied into place before
        // anything is copied over it.
        for _ in 0 ..< 3 { files.append(try nameless(in: folder)) }
        try put(input, into: files[0])
        guard lseek(files[0], 0, SEEK_SET) == 0 else { throw CheckFailure("could not rewind a file of the check's own") }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, file) in files.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, file, Int32(target))
        }
        for file in files where file > 2 {
            posix_spawn_file_actions_addclose(&actions, file)
        }

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
                      output: try contents(of: files[1]), errors: try contents(of: files[2]))
    }

    /// A new file in `folder`, open for reading and writing, and already
    /// without a name.
    static func nameless(in folder: String) throws -> Int32 {
        var template = Array((folder.hasSuffix("/") ? folder : folder + "/").utf8CString.dropLast())
            + Array("udeck-plugin-XXXXXX".utf8CString)
        let file = mkstemp(&template)
        guard file >= 0 else {
            throw CheckFailure("could not make a file in \(folder): \(String(cString: strerror(errno)))")
        }
        unlink(&template)
        return file
    }

    static func put(_ bytes: [UInt8], into file: Int32) throws {
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
            if count < 0 {
                guard errno == EINTR else { throw CheckFailure("could not write a file of the check's own") }
                continue
            }
            written += count
        }
    }

    /// Everything in `file`, from its start.
    static func contents(of file: Int32) throws -> [UInt8] {
        guard lseek(file, 0, SEEK_SET) == 0 else { throw CheckFailure("could not rewind a file of the check's own") }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count < 0 {
                guard errno == EINTR else { throw CheckFailure("could not read a file of the check's own") }
                continue
            }
            if count == 0 { return bytes }
            bytes += buffer[..<count]
        }
    }
}
