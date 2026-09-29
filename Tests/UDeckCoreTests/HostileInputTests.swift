import Foundation
import Testing
@testable import UDeckCore

/// The hostile inputs that concern uDeck rather than the plugin format: its own
/// poll schedule, and a layout file a person can edit. The manifest's share
/// is in `UDeckPluginFormat`'s tests.
@Suite("Hostile input, in uDeck")
struct HostileInputInUDeckTests {
    /// A producer that fails instantly used to cost exactly what a working one
    /// costs — a process spawned and reaped every interval, for as long as the
    /// panel was open.
    @Test("a plugin that keeps failing is asked less often, within bounds")
    func failuresBackOff() {
        let manifest = PluginManifest(
            id: PluginIdentifier(rawValue: "p")!, name: "P", version: "1.0.0", kind: .poll,
            run: ["./x"], interval: 5, timeout: 2
        )

        #expect(manifest.delay(afterConsecutiveFailures: 0) == 5)
        #expect(manifest.delay(afterConsecutiveFailures: 1) == 10)
        #expect(manifest.delay(afterConsecutiveFailures: 2) == 20)
        // Capped, and capped even when the exponent overflows to infinity.
        #expect(manifest.delay(afterConsecutiveFailures: 40) == PluginManifest.maximumPollBackoff)
        #expect(manifest.delay(afterConsecutiveFailures: 100_000) == PluginManifest.maximumPollBackoff)

        // A plugin that asked for a longer interval than the cap keeps it: the
        // backoff exists to slow polling down, never to speed it up.
        let slow = PluginManifest(
            id: PluginIdentifier(rawValue: "q")!, name: "Q", version: "1.0.0", kind: .poll,
            run: ["./x"], interval: 300, timeout: 5
        )
        #expect(slow.delay(afterConsecutiveFailures: 0) == 300)
        #expect(slow.delay(afterConsecutiveFailures: 9) == 300)
    }
}

/// The grid, given arrangements that are legal but large.
@Suite("Grid under load")
struct GridLoadTests {
    let columns = 12

    func stack(_ count: Int, height: Int) -> [GridWindow] {
        (0 ..< count).map { index in
            GridWindow(
                pluginID: PluginIdentifier(rawValue: "p")!,
                column: 0, row: index * height, width: columns, height: height
            )
        }
    }

    /// The previous algorithm pushed each overlapped window down and then
    /// re-examined whatever it now overlapped, so the work was not bounded by
    /// the number of windows. Past about 45 stacked windows it hit its own
    /// safety bound: an assertion in a debug build, and in a release build a
    /// silent early return that left overlapping windows — which were then
    /// saved to the layout file.
    @Test("a deep stack with a window dropped across it settles without overlaps")
    func deepStackConverges() {
        var windows = stack(60, height: 1)
        windows[0].height = 40
        let pinned = windows[0].id

        let started = Date()
        let result = GridEngine.normalized(windows, columns: columns, pinned: pinned)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1, "settling 60 windows took \(elapsed)s")
        #expect(result.count == windows.count)
        for (index, first) in result.enumerated() {
            for second in result[(index + 1)...] {
                #expect(!first.overlaps(second), "\(first.id) overlaps \(second.id)")
            }
        }
        #expect(result.first { $0.id == pinned }?.row == 0, "the window being placed keeps the top")
    }

    /// Gravity used to walk up one row at a time from wherever a window claimed
    /// to be, so a row of a billion in a layout file was a billion iterations
    /// on the main actor — the panel would simply stop.
    @Test("an absurd row in a layout file is bounded, not walked")
    func absurdRowIsClamped() {
        var window = GridWindow(
            pluginID: PluginIdentifier(rawValue: "p")!,
            column: 0, row: 1_000_000_000, width: 4, height: 2
        )
        window.height = 100_000

        let started = Date()
        let result = GridEngine.normalized([window], columns: columns)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1, "normalising one window took \(elapsed)s")
        #expect(result[0].row == 0)
        #expect(result[0].height == DeckLayout.maximumWindowHeight)
    }

    @Test("a layout file full of absurd rows still loads quickly and legally")
    func absurdLayoutLoads() throws {
        let tab = UUID()
        let windows = (0 ..< 40).map { index in
            """
            { "id": "\(UUID().uuidString)", "pluginID": "p", "column": \(index % 12),
              "row": \(900_000_000 + index), "width": 6, "height": 9000 }
            """
        }.joined(separator: ",")

        let json = """
        { "version": 1, "columns": 12, "selectedTabID": "\(tab.uuidString)",
          "tabs": [ { "id": "\(tab.uuidString)", "name": "Now", "windows": [\(windows)] } ] }
        """

        let started = Date()
        let layout = try JSONDecoder().decode(DeckLayout.self, from: Data(json.utf8)).normalized()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2, "normalising the layout took \(elapsed)s")
        let placed = layout.tabs[0].windows
        #expect(placed.count == 40)
        #expect(placed.allSatisfy { $0.height <= DeckLayout.maximumWindowHeight })
        #expect(placed.allSatisfy { $0.row <= DeckLayout.maximumWindowRow })
        for (index, first) in placed.enumerated() {
            for second in placed[(index + 1)...] {
                #expect(!first.overlaps(second))
            }
        }
    }

    @Test("settling is bounded even when every window wants the same cell")
    func everyWindowInOnePlace() {
        let windows = (0 ..< 120).map { _ in
            GridWindow(pluginID: PluginIdentifier(rawValue: "p")!,
                       column: 0, row: 0, width: columns, height: 2)
        }
        let started = Date()
        let result = GridEngine.normalized(windows, columns: columns)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(Set(result.map(\.row)).count == 120, "each should have landed on its own row")
    }
}

/// Identifiers arrive from a file the operator can edit, and the README invites
/// them to move that file between machines. The obvious way to clone a tab by
/// hand is to copy its JSON block — which duplicates every identifier in it.
@Suite("Duplicate identifiers")
struct DuplicateIdentifierTests {
    let plugin = PluginIdentifier(rawValue: "p")!

    /// This used to abort inside `Dictionary(uniqueKeysWithValues:)` — at
    /// launch, on the main actor, before any window or menu-bar item existed.
    /// A crash loop with Force Quit as the only exit and no way to reach the
    /// settings that would have fixed it.
    @Test("two windows sharing an id do not take the application down")
    func duplicateWindowIdSurvives() {
        let shared = UUID()
        let windows = [
            GridWindow(id: shared, pluginID: plugin, column: 0, row: 0, width: 6, height: 2),
            GridWindow(id: shared, pluginID: plugin, column: 6, row: 0, width: 6, height: 2),
        ]
        let tab = DeckTab(id: UUID(), name: "Now", windows: windows)
        let layout = DeckLayout(tabs: [tab]).normalized()

        let placed = layout.tabs[0].windows
        #expect(placed.count == 2, "the operator meant two windows; they should get two windows")
        #expect(Set(placed.map(\.id)).count == 2, "and the duplicate must be renumbered, not kept")
        #expect(!placed[0].overlaps(placed[1]))
    }

    @Test("two tabs sharing an id are renumbered, and the selection follows")
    func duplicateTabIdSurvives() {
        let shared = UUID()
        let layout = DeckLayout(
            tabs: [DeckTab(id: shared, name: "Now"), DeckTab(id: shared, name: "Home")],
            selectedTabID: shared
        ).normalized()

        #expect(layout.tabs.count == 2)
        #expect(Set(layout.tabs.map(\.id)).count == 2)
        #expect(layout.selectedTabID != nil)
        #expect(layout.tabs.contains { $0.id == layout.selectedTabID })
    }

    @Test("a hand-cloned tab in a layout file loads with both copies intact")
    func clonedTabBlockLoads() throws {
        let tab = UUID().uuidString
        let window = UUID().uuidString
        // Exactly what copying a tab's JSON block by hand produces.
        let block = """
        { "id": "\(tab)", "name": "Now", "windows": [
            { "id": "\(window)", "pluginID": "p", "column": 0, "row": 0, "width": 6, "height": 2 } ] }
        """
        let json = """
        { "version": 1, "columns": 12, "selectedTabID": "\(tab)", "tabs": [\(block), \(block)] }
        """

        let layout = try JSONDecoder().decode(DeckLayout.self, from: Data(json.utf8)).normalized()
        #expect(layout.tabs.count == 2)
        #expect(Set(layout.tabs.map(\.id)).count == 2)
        #expect(layout.tabs.allSatisfy { $0.windows.count == 1 })
        #expect(Set(layout.tabs.flatMap { $0.windows.map(\.id) }).count == 2)
    }

    @Test("the grid does not trap when handed a duplicate directly")
    func gridToleratesDuplicates() {
        let shared = UUID()
        let windows = (0 ..< 3).map { index in
            GridWindow(id: shared, pluginID: plugin, column: 0, row: index, width: 4, height: 1)
        }
        // The grid cannot invent identities — that belongs to the layout — but
        // it must not abort.
        let result = GridEngine.normalized(windows, columns: 12)
        #expect(result.count == 3)
    }
}
