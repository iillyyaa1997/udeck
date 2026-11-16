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

/// The command's own folder in the temporary folder (`ScratchFolder.home`),
/// which on Linux is shared: used only when it is this user's, a folder and
/// no link, writable by nobody else (audit F06).
@Suite("The command's own folder in a shared temporary folder")
struct ScratchFolderTests {
    static func place() -> URL {
        let base = TemporaryFolder.url.appendingPathComponent("udeck-scratch-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("made anew: this user's, a folder, 0700 — and its scratch folders in it")
    func madeAnew() throws {
        let base = Self.place()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("udeck-plugin-\(getuid())", isDirectory: true)
        let folder = try ScratchFolder.make(ScratchFolder.pinPrefix, in: home)
        var status = stat()
        #expect(lstat(home.path, &status) == 0 && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        #expect(status.st_uid == getuid() && status.st_mode & 0o777 == 0o700)
        #expect(folder.deletingLastPathComponent().path == home.path)
    }

    @Test("one somebody else could write in, or a link, is refused — nothing is made in it")
    func refused() throws {
        let base = Self.place()
        defer { try? FileManager.default.removeItem(at: base) }
        let open = base.appendingPathComponent("open", isDirectory: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        chmod(open.path, 0o777)
        #expect(throws: ScratchFolder.Unsafe.self) { _ = try ScratchFolder.make(in: open) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: open.path))?.isEmpty == true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        chmod(elsewhere.path, 0o700)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(throws: ScratchFolder.Unsafe.self) { _ = try ScratchFolder.make(in: link) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path))?.isEmpty == true)
    }
}
