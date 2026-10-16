import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// The temporary folder `udeck-plugin` and uDeck make their own folders in,
/// and hand a plugin (`TemporaryFolder`): `TMPDIR` when the run was given
/// one, which Foundation on a Mac does not honour by itself.
@Suite("The temporary folder a run was given")
struct TemporaryFolderTests {
    static let rows: [(String?, String?, String)] = [
        ("/private/tmp/scratch", "/private/tmp/scratch", "a folder by its full path"),
        ("/private/tmp/scratch/", "/private/tmp/scratch/", "as it is written: a plugin is handed exactly that"),
        ("/tmp/a folder of mine", "/tmp/a folder of mine", "a space is part of its name"),
        ("/", "/", "the root, as it is"),
        (nil, nil, "unset: the system's"),
        ("", nil, "empty: the system's"),
        ("scratch", nil, "relative: the system's — it would be another folder from every working directory"),
        ("./scratch/", nil, "relative: the system's"),
    ]

    @Test("TMPDIR when it names a folder by its full path, the system's otherwise", arguments: 0..<rows.count)
    func given(row: Int) {
        let (given, wanted, why) = Self.rows[row]
        #expect(TemporaryFolder.path(given: given) == (wanted ?? TemporaryFolder.system), "\(why)")
    }

    @Test("this process's own TMPDIR is where the command's folders and the tests' own are made")
    func thisProcess() {
        let given = ProcessInfo.processInfo.environment["TMPDIR"]
        #expect(TemporaryFolder.path == TemporaryFolder.path(given: given))
        #expect(TemporaryFolder.url == URL(fileURLWithPath: TemporaryFolder.path, isDirectory: true))
        #expect(ScratchFolder.home.deletingLastPathComponent().path == TemporaryFolder.url.path)
        #expect(ScratchFolder.home.lastPathComponent == "udeck-plugin-\(getuid())")
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        #expect(temp.url.resolvingSymlinksInPath().path
                    .hasPrefix(URL(fileURLWithPath: TemporaryFolder.path).resolvingSymlinksInPath().path + "/"),
                "\(temp.url.path) is not in \(TemporaryFolder.path)")
    }
}
