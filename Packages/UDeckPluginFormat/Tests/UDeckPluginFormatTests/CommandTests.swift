import Foundation
import Testing
import UDeckPluginCommand
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// `udeck-plugin` as a person or a CI job meets it: its arguments, what it
/// prints, and how it exits — 0 clean, 1 errors, 2 not checked at all.
@Suite("The udeck-plugin command")
struct CommandTests {
    struct Run {
        var status: Int32
        var output: [String]
        var errors: [String]
    }

    func run(_ arguments: String...) -> Run {
        run(arguments)
    }

    func run(_ arguments: [String]) -> Run {
        var output: [String] = []
        var errors: [String] = []
        let status = Command.run(arguments, environment: ProcessInfo.processInfo.environment, output: { output.append($0) },
                                 errors: { errors.append($0) })
        return Run(status: status, output: output, errors: errors)
    }

    @Test("--version and --help answer and succeed")
    func versionAndHelp() {
        #expect(run("--version").output == ["udeck-plugin \(UDeckRelease.version)"])
        #expect(run("--version").status == 0)
        let help = run("--help")
        #expect(help.status == 0)
        #expect(help.output.first?.hasPrefix("usage: udeck-plugin check") == true)
        #expect(help.errors.isEmpty)
    }

    @Test("wrong usage is exit status 2, with the usage on standard error", arguments: [
        [], ["frobnicate"], ["check"], ["check", "--official", "x"], ["check", "--strict=yes", "x"],
        ["check-repo", "somewhere"], ["check-repo", "--base", "a"], ["check-repo", "--head", "b"],
        ["check-repo", "--repo"], ["check-repo", "--repo", "a", "--repo", "b"], ["check-repo", "--frobnicate"],
        ["check-repo", "--base", "-x", "--head", "y"], ["check-repo", "--base=a", "--head", "--strict"],
    ])
    func usage(_ arguments: [String]) {
        var errors: [String] = []
        var output: [String] = []
        let status = Command.run(arguments, environment: [:], output: { output.append($0) }, errors: { errors.append($0) })
        #expect(status == 2, "\(arguments)")
        #expect(output.isEmpty, "\(arguments): \(output)")
        #expect(errors.joined().contains("usage: udeck-plugin"), "\(arguments)")
    }

    @Test("new, run, link and pin are not in this release", arguments: ["new", "run", "link", "pin"])
    func later(_ command: String) {
        let result = run(command, "x")
        #expect(result.status == 2)
        #expect(result.errors == ["udeck-plugin \(command): not in this release"])
        #expect(result.output.isEmpty)
    }

    @Test("check-repo prints each finding and a line that sums them up, as the Python check did")
    func checkRepository() throws {
        let clean = try TestRepository()
        let head = try clean.git("rev-parse", "HEAD")
        let passing = run("check-repo", "--official", "--repo", clean.folder.path)
        #expect(passing.status == 0)
        #expect(passing.output == ["checked 1 plugin folder at \(head.prefix(12)) as the official repository: 0 errors, 0 warnings"])

        let warned = try TestRepository(["plugins/sample/manifest.ru.json": nil])
        let warnings = run("check-repo", "--strict", "--repo", warned.folder.path)
        #expect(warnings.status == 0, "a warning does not fail the check")
        #expect(warnings.output.first == "warning: plugins/sample: has no manifest.<lang>.json; the plugin will show in English only [rule 11]")
        #expect(warnings.output.last?.hasSuffix(" strictly: 0 errors, 1 warning") == true)

        let broken = try TestRepository(["plugins/sample/README.md": nil, "udeck-plugins.json": nil])
        let failing = run("check-repo", "--strict", "--repo", broken.folder.path)
        #expect(failing.status == 1)
        #expect(failing.output.contains { $0.hasPrefix("error: udeck-plugins.json: is missing") && $0.hasSuffix("[passport]") })
        #expect(failing.output.contains("error: plugins/sample/README.md: is missing; it is what a reviewer and an installer read first [rule 10]"))
        #expect(failing.output.last?.hasSuffix(": 2 errors, 0 warnings") == true)
        #expect(run("check-repo", "--repo", broken.folder.path).output.last?.hasSuffix(": 1 error, 0 warnings") == true)
    }

    @Test("what cannot be checked is exit status 2, and says why")
    func couldNotCheck() throws {
        let temp = TemporaryDirectory()
        let result = run("check-repo", "--repo", temp.url.path)
        #expect(result.status == 2)
        #expect(result.output.first?.hasPrefix("could not check: HEAD is not a commit in") == true)
        let missing = run("check", temp.url.appendingPathComponent("nothing").path)
        #expect(missing.status == 2)
        #expect(missing.output.first?.hasSuffix("is not a folder") == true)
    }

    @Test("check takes plugin folders and exits with the worst of them")
    func check() throws {
        let repository = try TestRepository(["plugins/sample/README.md": nil])
        let head = try repository.git("rev-parse", "HEAD")
        let sample = repository.folder.appendingPathComponent("plugins/sample").path
        let installable = run("check", sample)
        #expect(installable.status == 0)
        #expect(installable.output == ["checked \(sample) at \(head.prefix(12)): 0 errors, 0 warnings"])
        let strict = run("check", "--strict", sample + "/")
        #expect(strict.status == 1)
        #expect(strict.output.last == "checked \(sample) at \(head.prefix(12)) strictly: 1 error, 0 warnings")
        let both = run("check", "--strict", sample, repository.temp.url.appendingPathComponent("absent").path)
        #expect(both.status == 2, "one folder that could not be checked outweighs errors in another")
        #expect(both.output.count == 3)
    }

    /// A run stopped by a signal leaves its index folder behind; the next run
    /// takes it away as it starts — both commands do.
    @Test("check and check-repo take away the folder a stopped run left", arguments: ["check", "check-repo"])
    func sweepAsItStarts(_ command: String) throws {
        let repository = try TestRepository()
        let left = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(ScratchFolder.prefix)\(Int32.max - 1)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: left) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * ScratchFolder.leftAfter)],
                                              ofItemAtPath: left.path)
        let result = command == "check"
            ? run("check", repository.folder.appendingPathComponent("plugins/sample").path)
            : run("check-repo", "--repo", repository.folder.path)
        #expect(result.status == 0, "\(result.output)")
        #expect(!FileManager.default.fileExists(atPath: left.path), "the folder a stopped run left is still there")
    }

    @Test("check takes a link to a plugin folder, and names the link")
    func checkThroughALink() throws {
        let repository = try TestRepository(["plugins/sample/README.md": nil])
        let head = try repository.git("rev-parse", "HEAD")
        let link = repository.temp.url.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository.folder.appendingPathComponent("plugins/sample"))
        let result = run("check", "--strict", link.path + "/")
        #expect(result.status == 1)
        #expect(result.output == [
            "error: \(link.path)/README.md: is missing; it is what a reviewer and an installer read first [rule 10]",
            "checked \(link.path) at \(head.prefix(12)) strictly: 1 error, 0 warnings",
        ])
    }
}
