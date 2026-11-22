import SwiftUI
import UDeckCore

/// The rows a resident plugin's card may take input with — chips, a feed, an
/// ask, a text field. uDeck draws them; what the person does goes back to the
/// plugin as an event (`send`). Nothing here knows what the plugin is about.

struct ChipsRowView: View {
    let items: [ChipItem]
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(items, id: \.id) { item in
                    Button { send(.select(id: item.id)) } label: {
                        HStack(spacing: 4) {
                            if let state = item.state, state != .ok {
                                Circle().fill(color(state)).frame(width: 6, height: 6)
                            }
                            Text(item.text).lineLimit(1)
                        }
                        .font(theme.chipFont)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(item.selected == true ? Color.accentColor : theme.recess))
                        .foregroundStyle(item.selected == true ? Color.white : theme.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("row.chip.\(item.id)")
                }
            }
        }
    }

    private func color(_ state: CardState) -> Color {
        switch state {
        case .warn: theme.warn
        case .crit: .red
        default: theme.dim
        }
    }
}

struct FeedRowView: View {
    let entries: [FeedEntry]
    let theme: DeckTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.id) { entry in
                        FeedEntryView(entry: entry, theme: theme).id(entry.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.backing))
            .frame(minHeight: 60, maxHeight: .infinity)
            .onChange(of: entries.last.map { $0.id + String($0.text.count) }) {
                if let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear { if let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }
}

private struct FeedEntryView: View {
    let entry: FeedEntry
    let theme: DeckTheme
    @State private var open = false

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(entry.text)
                    .font(theme.bodyFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(markdown(entry.text) + (entry.streaming == true ? AttributedString(" ▍") : AttributedString()))
                .font(theme.bodyFont)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                Button { open.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8))
                        Text(entry.text).lineLimit(1).truncationMode(.middle)
                        if entry.error == true { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                    }
                    .font(theme.chipFont)
                    .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                if open, let detail = entry.detail {
                    Text(detail)
                        .font(theme.chipFont)
                        .foregroundStyle(entry.error == true ? .red : theme.dim)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(theme.recess))
                }
            }
        case .note:
            Text(entry.text).font(theme.chipFont).foregroundStyle(theme.dim).frame(maxWidth: .infinity)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct AskRowView: View {
    let ask: AskRow
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.title).font(theme.bodyFont.weight(.semibold)).foregroundStyle(theme.text)
            if let detail = ask.detail, !detail.isEmpty {
                Text(detail)
                    .font(theme.chipFont)
                    .foregroundStyle(theme.muted)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.recess))
            }
            HStack(spacing: 6) {
                ForEach(ask.buttons, id: \.id) { button in
                    if button.primary == true {
                        Button(button.label) { send(.press(id: button.id)) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .accessibilityIdentifier("row.ask.\(button.id)")
                    } else {
                        Button(button.label) { send(.press(id: button.id)) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityIdentifier("row.ask.\(button.id)")
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.warn.opacity(0.7), lineWidth: 1))
    }
}

struct InputRowView: View {
    let input: InputRow
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(input.placeholder ?? "", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(theme.bodyFont)
                .lineLimit(1...6)
                .disabled(input.enabled == false)
                .onSubmit(submit)
                .onExitCommand { if let stop = input.stop { send(.press(id: stop)) } }
                .accessibilityIdentifier("row.input.\(input.id)")
            if let stop = input.stop {
                Button { send(.press(id: stop)) } label: { Image(systemName: "stop.fill") }
                    .controlSize(.small)
                    .accessibilityIdentifier("row.input.\(input.id).stop")
            }
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(.submit(row: input.id, text: text))
    }
}

extension Card {
    /// Whether the card holds a conversation, which takes the window's room.
    var hasFeed: Bool {
        rows.contains { if case .feed = $0 { true } else { false } }
    }
}
