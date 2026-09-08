import Foundation
@testable import UDeckCore

/// A real directory on disk, removed when the test is done.
///
/// Tests here use the actual filesystem rather than a fake one: everything
/// interesting about plugin discovery — the executable bit, a relative path
/// escaping its folder, an unreadable file — only exists on a real filesystem,
/// and a fake would have to reimplement exactly the behaviour under test.
final class TemporaryDirectory {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("udeck-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var paths: UDeckPaths { UDeckPaths(root: url) }

    @discardableResult
    func writePlugin(
        folder: String,
        manifest: String,
        script: (name: String, body: String, executable: Bool)? = nil
    ) -> URL {
        let directory = url.appendingPathComponent("plugins/\(folder)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        if let script {
            let file = directory.appendingPathComponent(script.name)
            try? Data(script.body.utf8).write(to: file)
            try? FileManager.default.setAttributes(
                [.posixPermissions: script.executable ? 0o755 : 0o644], ofItemAtPath: file.path
            )
        }
        return directory
    }
}

/// The repository's own `examples/` folder, which doubles as the fixture set:
/// the plugins shipped as documentation are the same ones the tests run.
enum RepositoryExamples {
    static var directory: URL {
        // …/Tests/UDeckCoreTests/TemporaryDirectory.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples", isDirectory: true)
    }

    static func plugin(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }
}
