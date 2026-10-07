import Foundation

/// A program a test writes and then runs.
///
/// On Linux a file that any process holds open for writing cannot be run:
/// exec fails with "Text file busy". Foundation's `Data.write(to:)` opens the
/// file without `O_CLOEXEC`, so a process another test starts at that moment
/// inherits the descriptor and holds the file open until it execs or exits —
/// and the test that runs its program a moment later fails for a reason that
/// has nothing to do with it (run 37637762329: `curl: Text file busy`). So the
/// bytes go to a file that is never run, and `cp`, in a process of its own,
/// makes the one that is: no descriptor of it ever exists in this process.
public enum Executable {
    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    /// Writes `text` to `url` with mode 0755.
    public static func write(_ text: String, to url: URL) throws {
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).staged")
        try Data(text.utf8).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        try? FileManager.default.removeItem(at: url)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [staged.path, url.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationReason == .exit, copy.terminationStatus == 0 else {
            throw Failed(description: "cp \(staged.path) \(url.path) exited \(copy.terminationStatus)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
