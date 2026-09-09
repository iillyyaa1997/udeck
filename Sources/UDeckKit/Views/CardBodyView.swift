import SwiftUI
import UDeckCore

/// Draws a card.
///
/// The host owns every pixel here. A plugin says "a meter at 0.32 labelled
/// week"; it does not say what a meter looks like. That is what makes a panel
/// of plugins from different authors read as one application, and what lets the
/// density setting mean something for plugins nobody has seen yet.
struct CardBodyView: View {
    var card: Card
    var presentation: CardPresentation
    var theme: DeckTheme
    var pluginID: PluginIdentifier
    var model: DeckModel
    @Bindable var shell: ShellState

    @State private var actionProblem: String?

    /// Stale values are shown at reduced contrast so that "old" is visible at a
    /// glance rather than only on inspection.
    private var contentOpacity: Double {
        switch presentation.freshness {
        case .fresh: 1
        case .stale: 0.55
        case .silent, .neverSpoke: 0.4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.rowSpacing) {
            if case .stale = presentation.freshness, let note = presentation.note {
                Text(note)
                    .font(theme.chipFont)
                    .foregroundStyle(theme.dim)
            }

            ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            .opacity(contentOpacity)

            if !card.actions.isEmpty {
                actions
            }

            if let actionProblem {
                Text(actionProblem)
                    .font(theme.chipFont)
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: CardRow) -> some View {
        switch row {
        case .text(let value):
            Text(value)
                .font(theme.bodyFont)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

        case .keyValue(let kv):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(kv.label).font(theme.monoFont).foregroundStyle(theme.muted)
                Spacer(minLength: 6)
                Text(kv.value)
                    .font(theme.monoFont)
                    .monospacedDigit()
                    .foregroundStyle(kv.state.map(theme.color(for:)) ?? theme.text)
            }

        case .meter(let meter):
            VStack(alignment: .leading, spacing: 4) {
                if meter.label != nil || meter.caption != nil {
                    HStack {
                        Text(meter.label ?? "").font(theme.monoFont).foregroundStyle(theme.muted)
                        Spacer(minLength: 6)
                        Text(meter.caption ?? "")
                            .font(theme.monoFont).monospacedDigit().foregroundStyle(theme.text)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.recess)
                        Capsule()
                            .fill(meter.state.map(theme.color(for:)) ?? theme.accent)
                            .frame(width: max(0, geometry.size.width * meter.value))
                    }
                }
                .frame(height: 5)
            }

        case .list(let items):
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 9) {
                        if let icon = item.icon {
                            Image(systemName: theme.symbol(for: icon))
                                .font(.system(size: 9))
                                .foregroundStyle(theme.color(for: icon))
                                .frame(width: 12)
                        }
                        Text(item.text)
                            .font(theme.monoFont)
                            .foregroundStyle(item.state.map(theme.color(for:)) ?? theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let note = item.note {
                            Text(note).font(theme.chipFont).foregroundStyle(theme.dim).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                    if index < items.count - 1 {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
            }

        case .spark(let spark):
            VStack(alignment: .leading, spacing: 4) {
                SparkView(values: spark.values, theme: theme)
                    .frame(height: theme.gridRowHeight * 0.7)
                if let caption = spark.caption {
                    Text(caption).font(theme.chipFont).foregroundStyle(theme.dim)
                }
            }

        case .table(let table):
            TableRowsView(table: table, theme: theme)

        case .log(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(theme.chipFont)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.windowCornerRadius - 4).fill(theme.recess))

        case .canvas(let canvas):
            // Described by the format so that adding it later cannot break
            // existing plugins, and deliberately not drawn in this version.
            // When it arrives it will be drawn inside a frame like this one, so
            // that a card drawing itself can never pass as one uDeck drew.
            VStack(alignment: .leading, spacing: 3) {
                Text("PLUGIN'S OWN DRAWING")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.dim)
                Text("\"\(canvas.kind)\" is not drawn by this version of uDeck")
                    .font(theme.chipFont)
                    .foregroundStyle(theme.muted)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.recess))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )

        case .unsupported(let kind):
            // Kept rather than dropped: a hole in a card with no explanation is
            // a bug report waiting to happen.
            Text("this plugin sent a \"\(kind)\" row, which this version of uDeck does not draw")
                .font(theme.chipFont)
                .foregroundStyle(theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 7) {
            // Keyed by position, not by content: a card may legitimately carry
            // two buttons with the same label and command, and identity by
            // content makes them collide.
            ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                Button(action.label) {
                    shell.onInteract()
                    run(action)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                .help(action.run.joined(separator: " "))
            }
            Spacer(minLength: 0)
        }
    }

    /// Runs an action, after asking when the plugin said to ask.
    ///
    /// The confirmation is the plugin author's call, but the permission is not:
    /// the host runs the command, and it refuses when this plugin was never
    /// granted the right to run it.
    private func run(_ action: CardAction) {
        if let question = action.confirm {
            let alert = NSAlert()
            alert.messageText = action.label
            alert.informativeText = question + "\n\n" + action.run.joined(separator: " ")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            // The panel sits at the status-bar level, so an ordinary alert
            // would open behind the thing that asked the question.
            alert.window.level = .popUpMenu
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        actionProblem = model.run(action, from: pluginID)
    }
}

/// A bar sparkline.
///
/// Draws exactly the numbers the producer sent and stores nothing. uDeck keeps
/// no history of its own in this version — and when it does, this row's shape
/// must not change, so that plugins written today keep working.
struct SparkView: View {
    var values: [Double]
    var theme: DeckTheme

    var body: some View {
        GeometryReader { geometry in
            let maximum = values.max() ?? 1
            let minimum = min(0, values.min() ?? 0)
            let span = max(maximum - minimum, 0.0001)
            let count = max(values.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.sparkline)
                        .frame(
                            width: barWidth,
                            height: max(1, geometry.size.height * (value - minimum) / span)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// A small table. Wide content scrolls sideways inside the window rather than
/// stretching it: a window's width belongs to the grid, not to its contents.
struct TableRowsView: View {
    var table: CardTable
    var theme: DeckTheme

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(column.title.uppercased())
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.dim)
                            .frame(minWidth: 40, alignment: column.align == .trailing ? .trailing : .leading)
                    }
                }
                .padding(.bottom, 5)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .font(theme.chipFont)
                                .monospacedDigit()
                                .foregroundStyle(theme.text)
                                .frame(
                                    minWidth: 40,
                                    alignment: table.columns.indices.contains(index)
                                        && table.columns[index].align == .trailing ? .trailing : .leading
                                )
                        }
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
                }
            }
        }
        .scrollIndicators(.never)
    }
}
