import Foundation
import Testing
@testable import AgentsCore

/// Paths in answers made links, and what a click does (uDeck 0.9.27, the
/// operator's «1» to question 205).
@Suite("Paths in answers")
@MainActor
struct AgentsPathLinksTests {
    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("Sources/Views/MessageEditor.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test("a path that exists becomes a file link with its line; one that does not, and versions, stay text")
    func links() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = URL(fileURLWithPath: folder.standardizedFileURL.path).absoluteString
        let text = "Причина в Sources/Views/MessageEditor.swift:154 — см. (notes.md). Вышла 0.9.24, а a/b.c нет."
        let linked = PathLinks.linkNow(text, folder: folder)
        #expect(linked == "Причина в [Sources/Views/MessageEditor.swift:154](\(base)Sources/Views/MessageEditor.swift#L154)"
            + " — см. ([notes.md](\(base)notes.md)). Вышла 0.9.24, а a/b.c нет.")
    }

    @Test("in backticks it stays code inside the link; fenced code and links already written are left alone")
    func code() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = URL(fileURLWithPath: folder.standardizedFileURL.path).absoluteString
        #expect(PathLinks.linkNow("Правка в `Sources/Views/MessageEditor.swift:12:3`", folder: folder)
            == "Правка в [`Sources/Views/MessageEditor.swift:12:3`](\(base)Sources/Views/MessageEditor.swift#L12)")
        let fenced = "```\ncat notes.md\n```"
        #expect(PathLinks.linkNow(fenced, folder: folder) == fenced)
        let written = "[заметки](notes.md) и https://example.com/a.b"
        #expect(PathLinks.linkNow(written, folder: folder) == written)
        let absolute = folder.appendingPathComponent("notes.md").path
        #expect(PathLinks.linkNow("Журнал: \(absolute).", folder: URL(fileURLWithPath: "/"))
            == "Журнал: [\(absolute)](\(base)notes.md).")
    }

    @Test("a click: the editor at the line, ⌘ Finder, ⌥ Quick Look, a folder in Finder")
    func open() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Sources/Views/MessageEditor.swift").standardizedFileURL.path
        let link = URL(fileURLWithPath: file).absoluteString + "#L154"
        #expect(FileOpener.command(link, keys: [], editor: "vscode")! == ("/usr/bin/open", ["vscode://file" + file + ":154"]))
        #expect(FileOpener.command(link, keys: [], editor: "xcode")! == ("/usr/bin/xed", ["--line", "154", file]))
        #expect(FileOpener.command(link, keys: [], editor: "system")! == ("/usr/bin/open", [file]))
        #expect(FileOpener.command(link, keys: ["command"], editor: "vscode")! == ("/usr/bin/open", ["-R", file]))
        #expect(FileOpener.command(link, keys: ["option"], editor: "vscode")! == ("/usr/bin/qlmanage", ["-p", file]))
        let dir = URL(fileURLWithPath: folder.appendingPathComponent("Sources").path).absoluteString
        #expect(FileOpener.command(dir, keys: [], editor: "vscode")! == ("/usr/bin/open", [folder.appendingPathComponent("Sources").standardizedFileURL.path]))
        #expect(FileOpener.command("https://example.com", keys: [], editor: "vscode") == nil)
        #expect(FileOpener.command("file:///no/such/file", keys: [], editor: "vscode") == nil)
    }
}
