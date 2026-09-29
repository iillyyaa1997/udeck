import Foundation
import Testing
@testable import UDeckCore

/// `UDeckPluginFormat` is built from the same commit as uDeck and says so with
/// uDeck's version. That number is written twice — in the app's Info.plist and
/// in the library — and this is what keeps the two the same.
@Suite("The plugin format's release")
struct PluginFormatReleaseTests {
    @Test("the format's version is the app's version")
    func versionIsTheApps() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/uDeck/Support/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        let version = try #require((info as? [String: Any])?["CFBundleShortVersionString"] as? String)
        #expect(UDeckRelease.version == version)
        #expect(SemanticVersion(UDeckRelease.version) != nil)
    }
}
