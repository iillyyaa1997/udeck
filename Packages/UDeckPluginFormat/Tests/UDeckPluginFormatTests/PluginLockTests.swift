import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// `.github/udeck-plugin.lock` (`PluginLock`): five lines, exactly as `pin`
/// writes them — and the shell's reading of it in docs/plugin-repository.md,
/// which a plugin repository's CI runs, held to the same answers.
@Suite("The lock file")
struct PluginLockTests {
    static let sums = ["macos-universal": String(repeating: "1", count: 64),
                       "linux-x86_64": String(repeating: "2", count: 64),
                       "linux-aarch64": "0123456789abcdef" + String(repeating: "f", count: 48)]
    static let digest = "sha256:" + String(repeating: "e", count: 64)
    static let good = PluginLock(version: SemanticVersion(major: 0, minor: 6, patch: 0), archives: sums, image: digest)

    static var goodLines: [String] { good.text.split(separator: "\n").map(String.init) }

    static func file(_ lines: [String]) -> [UInt8] { Array(lines.map { $0 + "\n" }.joined().utf8) }

    static func replacing(_ index: Int, with line: String) -> [UInt8] {
        var lines = goodLines
        lines[index] = line
        return file(lines)
    }

    @Test("pin writes five lines, key=value, in one order")
    func text() {
        #expect(Self.good.text == """
            version=0.6.0
            macos-universal=\(String(repeating: "1", count: 64))
            linux-x86_64=\(String(repeating: "2", count: 64))
            linux-aarch64=0123456789abcdef\(String(repeating: "f", count: 48))
            image=sha256:\(String(repeating: "e", count: 64))

            """)
        #expect(PluginLock.path == ".github/udeck-plugin.lock")
        #expect(PluginLock.archive("linux-x86_64", of: Self.good.version) == "udeck-plugin-0.6.0-linux-x86_64.tar.gz")
    }

    @Test("what pin writes reads back as itself")
    func roundTrip() throws {
        #expect(try PluginLock.read(Array(Self.good.text.utf8)) == Self.good)
        let largest = PluginLock(version: SemanticVersion(major: 999_999_999, minor: 0, patch: 999_999_999),
                                 archives: Self.sums, image: Self.digest)
        #expect(try PluginLock.read(Array(largest.text.utf8)) == largest)
    }

    /// Every way a file can be not quite a lock file, and what each is told.
    static let refused: [(name: String, bytes: [UInt8], said: String)] = {
        var cases: [(name: String, bytes: [UInt8], said: String)] = []
        let good = Array(Self.good.text.utf8)
        let hex = String(repeating: "a", count: 64)
        cases.append(("empty", [], "is empty"))
        cases.append(("a blank line alone", Array("\n".utf8), "line 1 is empty"))
        cases.append(("a byte order mark", [0xEF, 0xBB, 0xBF] + good, "byte order mark"))
        cases.append(("Windows line endings", Array(Self.good.text.replacingOccurrences(of: "\n", with: "\r\n").utf8),
                      "carriage return"))
        cases.append(("a carriage return on one line", Self.replacing(2, with: Self.goodLines[2] + "\r"), "line 3 holds a carriage return"))
        cases.append(("no line break at the end", Array(good.dropLast()), "does not end with a line break"))
        cases.append(("a carriage return for the last line break", Array(good.dropLast()) + [0x0D], "does not end with a line break"))
        cases.append(("a blank line at the end", good + [0x0A], "line 6 is empty"))
        cases.append(("a blank line inside", Self.file(Array(Self.goodLines[0 ..< 2]) + [""] + Array(Self.goodLines[2...])), "line 3 is empty"))
        cases.append(("a space before a key", Self.replacing(0, with: " version=0.6.0"), "space or a tab"))
        cases.append(("spaces around =", Self.replacing(0, with: "version = 0.6.0"), "space or a tab"))
        cases.append(("a space at the end", Self.replacing(4, with: Self.goodLines[4] + " "), "line 5 holds a space"))
        cases.append(("a tab", Self.replacing(1, with: "macos-universal=\t" + hex), "space or a tab"))
        cases.append(("uppercase hexadecimal", Self.replacing(1, with: "macos-universal=" + hex.uppercased()), "is not a sha256"))
        cases.append(("a short sum", Self.replacing(2, with: "linux-x86_64=" + hex.dropLast()), "is not a sha256"))
        cases.append(("a long sum", Self.replacing(3, with: "linux-aarch64=" + hex + "a"), "is not a sha256"))
        cases.append(("an empty sum", Self.replacing(3, with: "linux-aarch64="), "is not a sha256"))
        cases.append(("a version with its v", Self.replacing(0, with: "version=v0.6.0"), "is not X.Y.Z"))
        cases.append(("a leading zero", Self.replacing(0, with: "version=01.6.0"), "is not X.Y.Z"))
        cases.append(("a leading zero at the end", Self.replacing(0, with: "version=0.6.00"), "is not X.Y.Z"))
        cases.append(("two numbers", Self.replacing(0, with: "version=0.6"), "is not X.Y.Z"))
        cases.append(("four numbers", Self.replacing(0, with: "version=0.6.0.1"), "is not X.Y.Z"))
        cases.append(("ten digits", Self.replacing(0, with: "version=1000000000.0.0"), "is not X.Y.Z"))
        cases.append(("a suffix", Self.replacing(0, with: "version=0.6.0-beta"), "is not X.Y.Z"))
        cases.append(("an empty version", Self.replacing(0, with: "version="), "is not X.Y.Z"))
        cases.append(("== ", Self.replacing(0, with: "version==0.6.0"), "is not X.Y.Z"))
        cases.append(("a second =", Self.replacing(0, with: "version=0.6.0=1"), "is not X.Y.Z"))
        cases.append(("a key of no lock file", Self.file(Self.goodLines + ["format=1"]), "has no key \"format\""))
        cases.append(("a key in capitals", Self.replacing(0, with: "VERSION=0.6.0"), "has no key \"VERSION\""))
        cases.append(("a key spelt in Cyrillic", Self.replacing(0, with: "v\u{0435}rsion=0.6.0"), "has no key"))
        cases.append(("a comment", Self.file(["#pinned"] + Self.goodLines), "line 1 is not key=value"))
        cases.append(("a comment with a space", Self.file(["# pinned by hand"] + Self.goodLines), "space or a tab"))
        cases.append(("a key twice", Self.file(Self.goodLines + [Self.goodLines[0]]), "line 6: version again, after line 1"))
        cases.append(("the whole file twice", good + good, "again"))
        cases.append(("a key missing", Self.file(Array(Self.goodLines.dropLast())), "has no line image=…"))
        cases.append(("only the version", Self.file([Self.goodLines[0]]), "has no line macos-universal=…"))
        cases.append(("out of order", Self.file([Self.goodLines[4]] + Self.goodLines.dropLast()), "not in the order pin writes them"))
        cases.append(("two keys swapped", Self.file([Self.goodLines[0], Self.goodLines[2], Self.goodLines[1], Self.goodLines[3],
                                                     Self.goodLines[4]]), "not in the order"))
        cases.append(("an image without sha256:", Self.replacing(4, with: "image=" + hex), "is not a digest"))
        cases.append(("an image of another hash", Self.replacing(4, with: "image=sha512:" + hex + hex), "is not a digest"))
        cases.append(("an image with its name", Self.replacing(4, with: "image=ghcr.io/iillyyaa1997/udeck-plugin@sha256:" + hex),
                      "is not a digest"))
        cases.append(("a NUL byte in a sum", Self.replacing(1, with: "macos-universal=" + hex.dropLast() + "\u{0}"), "is not a sha256"))
        cases.append(("a NUL byte in the digest", Self.replacing(4, with: "image=sha256:\u{0}" + hex.dropFirst()), "is not a digest"))
        cases.append(("a byte that is not UTF-8", Array("version=0.6.".utf8) + [0xFF] + Array(good.drop { $0 != 0x0A }),
                      "\"0.6.\\xff\""))
        return cases
    }()

    @Test("everything else is refused, and said why")
    func refusals() {
        for (name, bytes, said) in Self.refused {
            do {
                let read = try PluginLock.read(bytes)
                Issue.record("\(name): read as \(read)")
            } catch let problem as PluginLock.Problem {
                #expect(problem.description.contains(said), "\(name): \(problem.description)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
    }

    // MARK: - The shell's reading

    /// The repository's docs/plugin-repository.md, found from this file.
    static let specification = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/plugin-repository.md")

    /// The shell function the specification gives, between its markers.
    static func reader() throws -> String {
        let text = try String(contentsOf: specification, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "<!-- lock-reader -->"), "no <!-- lock-reader --> in \(specification.path)")
        let end = try #require(lines.firstIndex(of: "<!-- /lock-reader -->"), "no <!-- /lock-reader -->")
        #expect(lines.filter { $0 == "<!-- lock-reader -->" }.count == 1)
        let block = Array(lines[(start + 1) ..< end])
        #expect(block.first == "```sh" && block.last == "```", "the reader is one sh block")
        return block.dropFirst().dropLast().joined(separator: "\n") + "\n"
    }

    /// The shells a CI job runs it with, those of them this machine has:
    /// `sh` everywhere — bash in its POSIX mode on a Mac, dash on Ubuntu —
    /// and bash, which GitHub Actions runs `run:` steps with.
    static let shells = ["/bin/sh", "/bin/bash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// What a file comes to: the five values, or refused.
    static func swiftReading(_ bytes: [UInt8]) -> String {
        guard let lock = try? PluginLock.read(bytes) else { return "refused" }
        return (["ok", lock.version.description] + PluginLock.platforms.map { lock.archives[$0] ?? "" } + [lock.image])
            .joined(separator: "\n")
    }

    @Test("the reader in the specification comes to udeck-plugin's answer on every file, good or not")
    func shellAgrees() throws {
        let reader = try Self.reader()
        #expect(reader.contains("read_udeck_plugin_lock() {"))
        #expect(!reader.contains("source") && !reader.contains("eval"), "the file is read, never run")
        #expect(Self.shells.contains("/bin/sh"))
        let temp = TemporaryDirectory()
        let script = temp.url.appendingPathComponent("read.sh")
        // Every file in one run of the shell, each answer ended by a line of
        // its own: hundreds of seds and cmps are quicker without a shell
        // started for each file.
        try Data((reader + """
            for lock in "$@"; do
                if read_udeck_plugin_lock "$lock" 2>/dev/null; then
                    printf 'ok\\n%s\\n%s\\n%s\\n%s\\n%s' "$version" "$macos_universal" "$linux_x86_64" "$linux_aarch64" "$image"
                else
                    printf 'refused'
                fi
                printf '\\n--end--\\n'
            done

            """).utf8).write(to: script)
        let goods: [(String, [UInt8])] = [
            ("as pin writes it", Array(Self.good.text.utf8)),
            ("the smallest version", Array(PluginLock(version: SemanticVersion(major: 0, minor: 0, patch: 0),
                                                      archives: Self.sums, image: Self.digest).text.utf8)),
            ("the largest version", Array(PluginLock(version: SemanticVersion(major: 999_999_999, minor: 999_999_999, patch: 1),
                                                     archives: Self.sums, image: Self.digest).text.utf8)),
            ("sums of zeros", Array(PluginLock(version: SemanticVersion(major: 1, minor: 10, patch: 100),
                                               archives: ["macos-universal": String(repeating: "0", count: 64),
                                                          "linux-x86_64": String(repeating: "0", count: 64),
                                                          "linux-aarch64": String(repeating: "9", count: 64)],
                                               image: "sha256:" + String(repeating: "0", count: 64)).text.utf8)),
        ]
        let corpus = goods + Self.refused.map { ($0.name, $0.bytes) }
        var files: [String] = []
        for (index, (_, bytes)) in corpus.enumerated() {
            let lock = temp.url.appendingPathComponent("lock-\(index)")
            try Data(bytes).write(to: lock)
            files.append(lock.path)
        }
        let swift = corpus.map { Self.swiftReading($0.1) }
        #expect(swift.filter { $0 != "refused" }.count == goods.count, "every good file is read and no other")
        for shell in Self.shells {
            let ran = try Subprocess.run([shell, script.path] + files,
                                         environment: ["PATH": "/usr/bin:/bin", "TMPDIR": temp.url.path])
            #expect(ran.status == 0, "\(shell): \(String(decoding: ran.errors, as: UTF8.self))")
            let said = String(decoding: ran.output, as: UTF8.self).components(separatedBy: "\n--end--\n").dropLast()
            #expect(said.count == corpus.count, "\(shell) answered \(said.count) of \(corpus.count) files")
            for (index, answer) in said.enumerated() where index < corpus.count && answer != swift[index] {
                Issue.record("\(corpus[index].0), \(shell): the shell says \(answer.debugDescription), udeck-plugin \(swift[index].debugDescription)")
            }
        }
        // mktemp's files are taken away whatever the answer.
        let left = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { !$0.hasPrefix("lock-") && $0 != "read.sh" }
        #expect(left.isEmpty, "\(left)")
        withExtendedLifetime(temp) {}
    }
}
