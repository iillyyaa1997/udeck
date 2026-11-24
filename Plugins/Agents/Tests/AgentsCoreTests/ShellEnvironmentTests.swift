import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

@Suite("The terminal's environment, for agents started by uDeck")
struct ShellEnvironmentTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-env-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("what a login shell's profile sets reaches the agents, banners before it do not")
    func capturesProfile() async throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(at: home) }
        // A stand-in login shell: chatty, sets PATH and a value with a newline in
        // it, then runs the command it was given, as `sh -c` would.
        let shell = home.appendingPathComponent("fake-shell")
        try """
        #!/bin/sh
        echo "Welcome to a chatty profile"
        export PATH="/opt/tools/bin:/usr/bin:/bin"
        export UDECK_MULTILINE="one
        two"
        shift 3
        exec /bin/sh -c "$1"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let environment = try await ShellEnvironment.capture(shell: shell.path, home: home.path, user: "someone")
        #expect(environment["PATH"] == "/opt/tools/bin:/usr/bin:/bin")
        #expect(environment["UDECK_MULTILINE"] == "one\ntwo")
        #expect(environment["HOME"] == home.path)
        #expect(environment["_"] == nil)
    }

    @Test("a shell that never finishes is given up on, not waited for")
    func timesOut() async throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = home.appendingPathComponent("stuck-shell")
        try "#!/bin/sh\nsleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        await #expect(throws: ShellEnvironment.Failure.timedOut) {
            _ = try await ShellEnvironment.capture(shell: shell.path, home: home.path, user: "someone",
                                                   timeout: .milliseconds(300))
        }
    }

    @Test("an executable is found on PATH in order, and a plain file or a missing one is not")
    func resolves() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "not executable".write(to: first.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: second.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: second.appendingPathComponent("claude").path)
        #expect(ShellEnvironment.resolve("claude", path: "\(first.path):\(second.path)")?.path
            == second.appendingPathComponent("claude").path)
        #expect(ShellEnvironment.resolve("codex", path: "\(first.path):\(second.path)") == nil)
    }
}
