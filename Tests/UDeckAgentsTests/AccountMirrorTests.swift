import Foundation
import Testing
@testable import UDeckAgents

@Suite("An extra account as a mirror of the main one")
struct AccountMirrorTests {
    static func folders() throws -> (root: URL, main: URL, mirror: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-mirror-" + UUID().uuidString)
        let main = root.appendingPathComponent("main"), mirror = root.appendingPathComponent("mirror")
        let manager = FileManager.default
        try manager.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try manager.createDirectory(at: main.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try "{}".write(to: main.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "{\"oauthAccount\":\"main\"}".write(to: main.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        return (root, main, mirror)
    }

    @Test("everything but the account's own login state is linked, and sessions are shared")
    func firstSetUp() throws {
        let (root, main, mirror) = try Self.folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let steps = try AccountMirror.reconcile(main: main, mirror: mirror)
        #expect(steps.count == 3)
        let manager = FileManager.default
        #expect(try manager.destinationOfSymbolicLink(atPath: mirror.appendingPathComponent("projects").path)
            == main.appendingPathComponent("projects").path)
        #expect(!manager.fileExists(atPath: mirror.appendingPathComponent(".claude.json").path))
        // A session written through either account is the same file.
        try "x".write(to: mirror.appendingPathComponent("projects/session.jsonl"), atomically: true, encoding: .utf8)
        #expect(manager.fileExists(atPath: main.appendingPathComponent("projects/session.jsonl").path))
        #expect((try manager.attributesOfItem(atPath: mirror.path)[.posixPermissions] as? Int) == 0o700)
    }

    @Test("reconcile links what the main folder grew since, and is a no-op when nothing changed")
    func reconcileLater() throws {
        let (root, main, mirror) = try Self.folders()
        defer { try? FileManager.default.removeItem(at: root) }
        try AccountMirror.reconcile(main: main, mirror: mirror)
        #expect(try AccountMirror.plan(main: main, mirror: mirror).isEmpty)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        #expect(try AccountMirror.reconcile(main: main, mirror: mirror)
            == [.link(name: "plugins", to: main.appendingPathComponent("plugins"))])
    }

    @Test("a real file the user put in the mirror is left alone, and a stray link is pointed back")
    func userFilesAndStrayLinks() throws {
        let (root, main, mirror) = try Self.folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: mirror, withIntermediateDirectories: true)
        try "mine".write(to: mirror.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: mirror.appendingPathComponent("skills"), withDestinationURL: root)
        let steps = try AccountMirror.reconcile(main: main, mirror: mirror)
        #expect(steps.contains(.keep(name: "settings.json")))
        #expect(steps.contains(.relink(name: "skills", to: main.appendingPathComponent("skills"))))
        #expect(try String(contentsOf: mirror.appendingPathComponent("settings.json"), encoding: .utf8) == "mine")
        #expect(try manager.destinationOfSymbolicLink(atPath: mirror.appendingPathComponent("skills").path)
            == main.appendingPathComponent("skills").path)
        #expect(manager.fileExists(atPath: root.path)) // the stray link's target survived
    }
}
