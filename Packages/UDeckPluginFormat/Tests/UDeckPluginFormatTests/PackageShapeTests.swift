import Foundation
import Testing
@testable import UDeckPluginFormat

/// What the package promises about itself, held where a slip would otherwise
/// only show on a Linux runner, or not at all.
@Suite("The package's own shape")
struct PackageShapeTests {

    /// The library's sources, found from this file: `Tests/UDeckPluginFormatTests/`
    /// sits next to `Sources/UDeckPluginFormat/`.
    static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/UDeckPluginFormat", isDirectory: true)

    static func swiftFiles() throws -> [URL] {
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Full Foundation is only ever the fallback of an
    /// `#if canImport(FoundationEssentials)`. A plain `import Foundation` would
    /// still build on Linux — the toolchain has it — and quietly bring ICU and
    /// every Foundation extension into the whole module, which is exactly what
    /// the Linux job cannot notice.
    @Test("every source imports Foundation only where FoundationEssentials is missing")
    func foundationOnlyAsTheFallback() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 10, "found the library's sources at \(Self.sources.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for (index, line) in lines.enumerated() where line == "import Foundation" {
                let before = lines[..<index].last { !$0.isEmpty } ?? ""
                #expect(before == "#else", "\(file.lastPathComponent):\(index + 1) imports Foundation outside the fallback")
                #expect(lines.contains("#if canImport(FoundationEssentials)"),
                        "\(file.lastPathComponent) has no FoundationEssentials branch")
            }
        }
    }

    /// The grid's two limits are the contract's numbers — a manifest's
    /// `defaultWidth` may be 1 to 12, a window at most 24 rows tall — and uDeck's
    /// layout takes them from here. Compared with themselves elsewhere, they
    /// would change with nothing turning red.
    @Test("the grid is 12 columns wide and a window at most 24 rows tall")
    func gridLimits() {
        #expect(PluginWindowLimits.gridColumns == 12)
        #expect(PluginWindowLimits.maximumHeight == 24)
    }
}
