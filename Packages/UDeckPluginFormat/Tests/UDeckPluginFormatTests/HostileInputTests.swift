import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

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

    /// Validation rejects the value; the settings row still draws a subtitle
    /// for the plugin it rejected, and `Int(someDouble)` traps outside `Int`'s
    /// range. Two correct behaviours that killed the window between them.
    @Test("an interval no integer can hold has no whole-second form, rather than trapping")
    func absurdIntervalHasNoWholeSeconds() {
        func manifest(interval: TimeInterval?) -> PluginManifest {
            PluginManifest(
                id: PluginIdentifier(rawValue: "p")!, name: "P", version: "1.0.0", kind: .poll,
                run: ["./x"], interval: interval, timeout: 2
            )
        }

        #expect(manifest(interval: 1e308).intervalInWholeSeconds == nil)
        #expect(manifest(interval: -1e308).intervalInWholeSeconds == nil)
        #expect(manifest(interval: .infinity).intervalInWholeSeconds == nil)
        #expect(manifest(interval: .nan).intervalInWholeSeconds == nil)
        #expect(manifest(interval: nil).intervalInWholeSeconds == nil)

        #expect(manifest(interval: 5).intervalInWholeSeconds == 5)
        #expect(manifest(interval: 5.4).intervalInWholeSeconds == 5)
        #expect(manifest(interval: 5.6).intervalInWholeSeconds == 6)
    }

    /// Positive, finite, inside the ceiling — and converted to nanoseconds it
    /// truncates to nothing, so the poll loop becomes "spawn a process, reap
    /// it, spawn another" for as long as the panel is open.
    @Test("an interval too small to sleep on is rejected, not accepted as very eager")
    func tinyDurationsAreRejected() {
        func manifest(_ interval: TimeInterval, _ timeout: TimeInterval) -> PluginManifest {
            PluginManifest(
                id: PluginIdentifier(rawValue: "p")!, name: "P", version: "1.0.0", kind: .poll,
                run: ["./x"], interval: interval, timeout: timeout
            )
        }

        #expect(Seconds.nanoseconds(1e-12) == 0, "the premise: this sleep is no sleep")

        let tiny = manifest(1e-12, 1e-13).problems()
        #expect(tiny.contains {
            if case .durationTooShort(let field, _, _) = $0 { return field == "interval" }
            return false
        })
        #expect(tiny.contains {
            if case .durationTooShort(let field, _, _) = $0 { return field == "timeout" }
            return false
        })

        // The floor is a floor, not a taste: what the examples ship still passes.
        #expect(!manifest(5, 3).problems().contains {
            if case .durationTooShort = $0 { return true } else { return false }
        })
    }

    /// The width is bounded and the grid clamps to it. A manifest that says
    /// 100000 and a panel that draws 24 is the shape of bug where the file and
    /// the screen disagree and nobody is told which won.
    @Test("a window hint taller than the grid allows is reported, not silently clamped")
    func absurdWindowHeightIsReported() {
        func manifest(height: Int) -> PluginManifest {
            PluginManifest(
                id: PluginIdentifier(rawValue: "p")!, name: "P", version: "1.0.0", kind: .poll,
                run: ["./x"], interval: 5, timeout: 2,
                window: WindowHints(defaultWidth: 4, defaultHeight: height,
                                    minimumWidth: 1, minimumHeight: 1)
            )
        }

        #expect(manifest(height: 100_000).problems().contains {
            if case .invalidWindowHints = $0 { return true } else { return false }
        })
        #expect(!manifest(height: PluginWindowLimits.maximumHeight).problems().contains {
            if case .invalidWindowHints = $0 { return true } else { return false }
        })
    }

    // MARK: - Setting ranges

    /// A manifest may declare one end of a range and not the other. Reversed
    /// bounds are a *fatal error* in SwiftUI's stepper rather than an empty
    /// range, so a perfectly valid manifest could crash the settings screen.
    @Test("a setting range is legal however the manifest declares it")
    func editingRangeIsAlwaysLegal() {
        let cases: [(minimum: Int?, maximum: Int?)] = [
            (nil, nil), (2000, nil), (nil, 5), (10, 5), (0, 0), (-50, nil), (nil, -50),
            // A one-sided minimum at the top of the range: adding the default
            // span to it overflows, and overflow is a trap, not a large number.
            (Int.max, nil), (Int.max - 1, nil), (Int.min, nil), (Int.max, Int.max),
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

/// The byte cap on a producer's output is the wrong unit for what actually
/// hurts: a megabyte of tiny rows is well inside it and enough to stop the
/// panel responding while it lays them out.
@Suite("Card size")
struct CardSizeTests {
    @Test("a card with tens of thousands of rows is cut down, and says so")
    func manyRowsAreCut() {
        let card = Card(rows: (0 ..< 80_000).map { .text("row \($0)") })
        let drawn = card.withinDrawingLimits()

        #expect(drawn.rows.count == CardLimits.standard.rows + 1, "the extra row is the notice")
        guard case .text(let notice) = drawn.rows.last else { Issue.record("expected a notice"); return }
        #expect(notice.contains("cut short"))
        // The rows that survive are the first ones, in order.
        guard case .text(let first) = drawn.rows.first else { Issue.record("expected a text row"); return }
        #expect(first == "row 0")
    }

    @Test("a single enormous string is trimmed rather than laid out")
    func longStringsAreTrimmed() {
        let huge = String(repeating: "x", count: 500_000)
        let drawn = Card(chip: huge, rows: [.text(huge), .keyValue(KeyValueRow(label: huge, value: huge))])
            .withinDrawingLimits()

        #expect((drawn.chip?.count ?? 0) <= CardLimits.standard.textLength + 1)
        guard case .text(let text) = drawn.rows[0] else { Issue.record("expected a text row"); return }
        #expect(text.count <= CardLimits.standard.textLength + 1)
        guard case .keyValue(let kv) = drawn.rows[1] else { Issue.record("expected a kv row"); return }
        #expect(kv.label.count <= CardLimits.standard.textLength + 1)
        #expect(kv.value.count <= CardLimits.standard.textLength + 1)
    }

    @Test("every collection inside a row is bounded too")
    func nestedCollectionsAreCut() {
        let card = Card(rows: [
            .list((0 ..< 10_000).map { ListItem(text: "item \($0)") }),
            .spark(SparkRow(values: Array(repeating: 1, count: 10_000))),
            .log((0 ..< 10_000).map { "line \($0)" }),
            .table(CardTable(
                columns: (0 ..< 200).map { CardTableColumn(title: "c\($0)") },
                rows: (0 ..< 10_000).map { _ in (0 ..< 200).map(String.init) }
            )),
        ])
        let drawn = card.withinDrawingLimits()
        let limits = CardLimits.standard

        guard case .list(let items) = drawn.rows[0] else { Issue.record("expected a list"); return }
        #expect(items.count == limits.listItems)
        guard case .spark(let spark) = drawn.rows[1] else { Issue.record("expected a spark"); return }
        #expect(spark.values.count == limits.sparkValues)
        guard case .log(let lines) = drawn.rows[2] else { Issue.record("expected a log"); return }
        #expect(lines.count == limits.logLines)
        guard case .table(let table) = drawn.rows[3] else { Issue.record("expected a table"); return }
        #expect(table.columns.count == limits.tableColumns)
        #expect(table.rows.count == limits.tableRows)
        #expect(table.rows.allSatisfy { $0.count == limits.tableColumns },
                "cells beyond the surviving columns would have nowhere to go")
    }

    @Test("a wall of buttons is cut down like any other collection")
    func manyActionsAreCut() {
        let card = Card(
            rows: [.text("fine")],
            actions: (0 ..< 30_000).map { CardAction(label: "do \($0)", run: ["true"]) }
        )
        let drawn = card.withinDrawingLimits()

        #expect(drawn.actions.count == CardLimits.standard.actions)
        #expect(drawn.actions.first?.label == "do 0")
        guard case .text(let notice) = drawn.rows.last else { Issue.record("expected a notice"); return }
        #expect(notice.contains("cut short"))
    }

    @Test("an action's own strings are trimmed, argv included")
    func actionStringsAreTrimmed() {
        let huge = String(repeating: "x", count: 500_000)
        let drawn = Card(rows: [], actions: [
            CardAction(label: huge, run: ["open"] + Array(repeating: huge, count: 500), confirm: huge),
        ]).withinDrawingLimits()

        let action = try! #require(drawn.actions.first)
        #expect(action.label.count <= CardLimits.standard.textLength + 1)
        #expect(action.confirm?.count ?? 0 <= CardLimits.standard.textLength + 1)
        #expect(action.run.count == CardLimits.standard.actionArguments)
        #expect(action.run.allSatisfy { $0.count <= CardLimits.standard.textLength + 1 })
    }

    @Test("a row uDeck does not understand is trimmed like the ones it does")
    func diagnosticRowsAreTrimmed() {
        let huge = String(repeating: "x", count: 900_000)
        let drawn = Card(rows: [
            .unsupported(kind: huge),
            .canvas(CanvasRow(kind: huge, payload: huge, height: 40)),
        ]).withinDrawingLimits()

        guard case .unsupported(let kind) = drawn.rows.first else {
            Issue.record("expected the diagnostic row"); return
        }
        #expect(kind.count <= CardLimits.standard.textLength + 1)

        guard case .canvas(let canvas) = drawn.rows.dropFirst().first else {
            Issue.record("expected the canvas row"); return
        }
        #expect(canvas.kind.count <= CardLimits.standard.textLength + 1)
        #expect(canvas.payload?.count ?? 0 <= CardLimits.standard.textLength + 1)
        #expect(canvas.height == 40)
    }

    @Test("a card that already fits is returned unchanged, with no notice added")
    func smallCardsAreUntouched() {
        let card = Card(
            state: .warn, chip: "16 waiting",
            rows: [.text("hello"), .list([ListItem(text: "x", note: "y", icon: .wait)])],
            ttl: 20
        )
        #expect(card.withinDrawingLimits() == card)
    }
}
