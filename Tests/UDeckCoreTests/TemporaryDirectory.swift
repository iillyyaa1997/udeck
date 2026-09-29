import Foundation
@testable import UDeckCore
import UDeckPluginFormatFixtures

// `TemporaryDirectory` itself lives with the plugin format's tests, which use it
// too; uDeck's tests also want it as a whole `~/.udeck`.
extension TemporaryDirectory {
    var paths: UDeckPaths { UDeckPaths(root: url) }
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
