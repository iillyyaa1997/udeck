import Foundation
import Testing
@testable import UDeckCore

/// Inputs that reach uDeck from somewhere it does not control — a plugin's
/// manifest, or a layout file a person can edit — and that used to take the
/// whole application down rather than being reported.
///
/// None of these needs malice. Every one of them is a plausible typo.
@Suite("Hostile input")
struct HostileInputTests {
    // MARK: - Durations

    /// `UInt64(seconds * 1_000_000_000)` traps past about 585 years, and a trap
    /// cannot be caught: it aborts the process. Worse, the plugin's window is by
    /// then in the layout file, so the abort repeats on every launch and the
    /// only way out is editing files by hand.
    @Test("an absurd duration saturates instead of trapping")
    func secondsSaturate() {
        #expect(Seconds.nanoseconds(5) == 5_000_000_000)
        #expect(Seconds.nanoseconds(0) == 0)
        #expect(Seconds.nanoseconds(-1) == 0)
        #expect(Seconds.nanoseconds(.infinity) == 0)
        #expect(Seconds.nanoseconds(.nan) == 0)
        // The value from the report that aborted the app.
        #expect(Seconds.nanoseconds(20_000_000_000) == UInt64(Seconds.ceiling * 1_000_000_000))
        #expect(Seconds.nanoseconds(.greatestFiniteMagnitude) == UInt64(Seconds.ceiling * 1_000_000_000))
    }

    @Test("a manifest asking for an impossible interval is reported, not silently changed")
    func absurdIntervalIsReported() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data("""
        { "id": "slow", "name": "Slow", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./x"], "interval": 20000000000, "timeout": 10000000000 }
        """.utf8))

        let problems = manifest.problems()
        #expect(!problems.isEmpty, "this manifest used to validate cleanly and then abort the app")
        #expect(problems.contains {
            if case .durationOutOfRange(let field, _, _) = $0 { return field == "interval" }
            return false
        })
        #expect(problems.contains {
            if case .durationOutOfRange(let field, _, _) = $0 { return field == "timeout" }
            return false
        })
    }

    @Test("a non-finite duration is reported as non-positive rather than accepted")
    func nonFiniteDuration() {
        let manifest = PluginManifest(
            id: PluginIdentifier(rawValue: "p")!, name: "P", version: "1.0.0", kind: .poll,
            run: ["./x"], interval: .infinity, timeout: .nan
        )
        #expect(manifest.problems().contains(.nonPositiveInterval(.infinity)))
        #expect(manifest.problems().contains { if case .nonPositiveTimeout = $0 { true } else { false } })
    }

    // MARK: - Setting ranges

    /// A manifest may declare one end of a range and not the other. Reversed
    /// bounds are a *fatal error* in SwiftUI's stepper rather than an empty
    /// range, so a perfectly valid manifest could crash the settings screen.
    @Test("a setting range is legal however the manifest declares it")
    func editingRangeIsAlwaysLegal() {
        let cases: [(minimum: Int?, maximum: Int?)] = [
            (nil, nil), (2000, nil), (nil, 5), (10, 5), (0, 0), (-50, nil), (nil, -50),
        ]
        for bounds in cases {
            let declaration = SettingDeclaration(
                key: "n", type: .int, label: "How many", defaultValue: .int(0),
                minimum: bounds.minimum, maximum: bounds.maximum
            )
            let range = declaration.editingRange
            #expect(range.lowerBound <= range.upperBound,
                    "min \(String(describing: bounds.minimum)) max \(String(describing: bounds.maximum)) produced \(range)")
        }
    }

    @Test("a declared minimum is honoured when only it is given")
    func minimumWithoutMaximum() {
        let declaration = SettingDeclaration(
            key: "n", type: .int, label: "How many", defaultValue: .int(5000), minimum: 2000
        )
        #expect(declaration.editingRange.lowerBound == 2000)
        #expect(declaration.editingRange.upperBound == 2000 + SettingDeclaration.defaultIntegerSpan)
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
