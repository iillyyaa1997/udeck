import Foundation
import UDeckAgents

/// The environment a terminal would give an agent, for an app that has none.
///
/// uDeck starts from launchd, with launchd's few variables: no PATH from the
/// user's shell profile (so no Homebrew, nvm or `~/.local/bin`), none of their
/// proxies or tool settings. An agent started with that finds neither itself nor
/// the tools it runs. So the user's login shell is asked once — interactively,
/// as a new terminal tab would run it — and what it ends up with is what the
/// agents get.
public enum ShellEnvironment {
    public enum Failure: Error, Equatable {
        case timedOut
        case noOutput(String)
    }

    static let marker = "UDECK-ENVIRONMENT-BEGINS"

    /// Runs `shell -l -i -c` and returns the environment it ends with.
    ///
    /// The profile may print anything (a banner, a warning about the missing
    /// terminal); the environment starts after a marker and is NUL-separated, so
    /// values with newlines in them survive.
    public static func capture(shell: String, home: String, user: String,
                               timeout: Duration = .seconds(15)) async throws -> [String: String]
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n%s\\n' \(marker); /usr/bin/env -0"]
        process.environment = ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "TERM": "dumb",
                               "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let reading = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let finished = Task.detached { () -> Bool in
            let deadline = ContinuousClock.now + timeout
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return true
        }
        guard await finished.value else {
            reading.cancel()
            throw Failure.timedOut
        }
        return try parse(await reading.value)
    }

    static func parse(_ data: Data) throws -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "\n\(marker)\n") else {
            throw Failure.noOutput(String(text.prefix(200)))
        }
        var environment: [String: String] = [:]
        for entry in text[range.upperBound...].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        // The shell's own bookkeeping, not the user's environment.
        for key in ["_", "SHLVL", "OLDPWD", "PWD"] { environment.removeValue(forKey: key) }
        return environment
    }

    /// The first executable called `name` on `path`, as a shell would find it.
    public static func resolve(_ name: String, path: String) -> URL? {
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
