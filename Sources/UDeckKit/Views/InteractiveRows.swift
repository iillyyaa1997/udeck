import AppKit
import SwiftUI
import UDeckCore
import UniformTypeIdentifiers

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
    @State private var openGroups: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(FeedLayout.items(entries)) { item in
                        switch item {
                        case .entry(let entry):
                            FeedEntryView(entry: entry, theme: theme).id(item.id)
                        case .tools(let group):
                            ToolGroupView(entries: group, theme: theme, open: Binding(
                                get: { openGroups.contains(item.id) },
                                set: { if $0 { openGroups.insert(item.id) } else { openGroups.remove(item.id) } }
                            )).id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("feed-end")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            // Shown again — back from a window of its own, a tab switched to —
            // it opens on the newest entry: scrolling there on appearing alone
            // landed half-way, the lazy stack not laid out yet. Only where it
            // starts: a short conversation stays at the top, not pushed down.
            .modifier(StartsAtTheBottom())
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.backing))
            // It gives way first: a question or the field under it is never
            // pushed out, nor the title line above.
            .frame(minHeight: 24, maxHeight: .infinity)
            .onChange(of: entries.last.map { $0.id + String($0.text.count) + String($0.detail?.count ?? 0) }) {
                proxy.scrollTo("feed-end", anchor: .bottom)
            }
            // Again once the lazy stack has been laid out: on appearing alone
            // it measured entries not drawn yet and stopped half-way.
            .onAppear {
                proxy.scrollTo("feed-end", anchor: .bottom)
                DispatchQueue.main.async { proxy.scrollTo("feed-end", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo("feed-end", anchor: .bottom) }
            }
        }
    }
}

/// Two or more operations in a row: one quiet line, «4 действия · Bash ×2,
/// Read ×2», that opens to the lines themselves.
private struct ToolGroupView: View {
    let entries: [FeedEntry]
    let theme: DeckTheme
    @Binding var open: Bool
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(strings(.feedActions(count: entries.count)) + " · " + FeedLayout.toolSummary(entries))
                        .lineLimit(1).truncationMode(.tail)
                    if entries.contains(where: { $0.error == true }) {
                        Text("· " + strings(.feedActionFailed)).foregroundStyle(theme.crit)
                    } else if entries.last?.streaming == true {
                        Text("· " + strings(.feedActionRunning)).foregroundStyle(theme.warn)
                    }
                }
                .font(theme.smallFont)
                .foregroundStyle(theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("row.feed.group.\(entries.first?.id ?? "")")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries, id: \.id) { FeedEntryView(entry: $0, theme: theme) }
                }
                .padding(.leading, 12)
            }
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
            VStack(alignment: .trailing, spacing: 2) {
                if let files = entry.files, !files.isEmpty {
                    HStack {
                        Spacer(minLength: 30)
                        MessageFiles(paths: files, theme: theme, entryID: entry.id)
                    }
                    .padding(.bottom, 2)
                }
                // A picture sent with no words is its picture alone.
                if !entry.text.isEmpty {
                HStack {
                    Spacer(minLength: 30)
                    Text(entry.text)
                        .font(theme.bodyFont)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13,
                                                           bottomTrailingRadius: 4, topTrailingRadius: 13)
                            .fill(Color.accentColor.opacity(entry.label == nil ? 1 : 0.55)))
                        .foregroundStyle(.white)
                }
                }
                // A message's state, under it: queued behind the running turn.
                if let label = entry.label, !label.isEmpty {
                    Text(label).font(theme.smallFont).foregroundStyle(theme.dim)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
                if let label = entry.label, !label.isEmpty {
                    Text(label).font(theme.smallFont).foregroundStyle(theme.dim)
                }
                MarkdownBlocks(text: entry.text, streaming: entry.streaming == true, theme: theme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(entry.name ?? "").fontWeight(.semibold).foregroundStyle(
                            entry.streaming == true ? theme.warn : theme.muted)
                        Text(entry.name.map { entry.text.hasPrefix($0) ? String(entry.text.dropFirst($0.count))
                            .trimmingCharacters(in: .whitespaces) : entry.text } ?? entry.text)
                            .lineLimit(1).truncationMode(.middle)
                        if entry.error == true { Image(systemName: "exclamationmark.circle").foregroundStyle(theme.crit) }
                    }
                    .font(theme.monoFont.weight(.regular))
                    .foregroundStyle(theme.dim)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open, let detail = entry.detail {
                    Text(detail)
                        .font(theme.chipFont)
                        .foregroundStyle(entry.error == true ? theme.crit : theme.dim)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(theme.recess))
                }
            }
        case .note:
            Text(entry.text).font(theme.smallFont).foregroundStyle(theme.dim).frame(maxWidth: .infinity)
        }
    }
}

/// Markdown as a feed draws it: paragraphs, bullet and numbered lists,
/// headings and fenced code, with inline emphasis, code and links. Not a
/// renderer for documents — what an answer in a conversation uses.
struct MarkdownBlocks: View {
    let text: String
    let streaming: Bool
    let theme: DeckTheme

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        let blocks = MarkdownBlock.blocks(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let caret = streaming && index == blocks.count - 1 ? AttributedString(" ▍") : AttributedString()
                switch block {
                case .paragraph(let value):
                    Text(Self.inline(value) + caret).font(theme.bodyFont)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(theme.bodyFont).foregroundStyle(theme.muted)
                        Text(Self.inline(value) + caret).font(theme.bodyFont)
                    }
                case .numbered(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(theme.bodyFont).foregroundStyle(theme.muted).monospacedDigit()
                        Text(Self.inline(value) + caret).font(theme.bodyFont)
                    }
                case .heading(let value):
                    Text(Self.inline(value) + caret).font(theme.bodyFont.weight(.semibold))
                case .code(let value):
                    Text(AttributedString(value) + caret)
                        .font(theme.monoFont)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.recess))
                }
            }
            if blocks.isEmpty && streaming { Text("▍").font(theme.bodyFont) }
        }
        .foregroundStyle(theme.text)
        .textSelection(.enabled)
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
    /// Whose field this is — the card's window and the row — for `Drafts`.
    var draftKey: String = ""
    @Environment(\.strings) private var strings

    /// What is typed here, kept outside the view (`Drafts`).
    private var draft: String {
        get { Drafts.shared.texts[key] ?? "" }
        nonmutating set { Drafts.shared.texts[key] = newValue.isEmpty ? nil : newValue }
    }

    private var key: String { draftKey + "/" + input.id }

    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { draft = $0 })
    }

    /// The files going with the message, kept outside the view as the text is.
    private var files: [URL] {
        get { Drafts.shared.files[key] ?? [] }
        nonmutating set { Drafts.shared.files[key] = newValue.isEmpty ? nil : newValue }
    }

    private var takesFiles: Bool { input.files == true && input.enabled != false }

    @State private var dropping = false
    /// The field's suggestions (0.9.25): open or not, where, for what.
    @State private var suggesting = SuggestState()
    @State private var handle = EditorHandle()
    /// Room above the field in the card, for the list over it.
    @State private var roomAbove: CGFloat = 240

    private var suggest: InputSuggest? {
        guard let suggest = input.suggest, !suggest.tabs.isEmpty, input.enabled != false else { return nil }
        return suggest
    }

    var body: some View {
        Group {
            if let pickers = input.pickers, !pickers.isEmpty {
                panel(pickers)
            } else {
                line
            }
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { roomAbove = geometry.frame(in: .named(CardBodyView.space)).minY }
                .onChange(of: geometry.frame(in: .named(CardBodyView.space)).minY) { _, top in roomAbove = top }
        })
        .overlay(alignment: .top) {
            if let suggest, suggesting.open {
                let height = max(90, min(300, roomAbove - 8))
                SuggestList(rowID: input.id, suggest: suggest, theme: theme, state: suggesting, maxHeight: height,
                            pick: pick, send: send)
                    .frame(height: height, alignment: .bottom)
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
        .onChange(of: input.suggest == nil) { _, gone in if gone { suggesting.close() } }
        .onDrop(of: [.fileURL], isTargeted: takesFiles ? $dropping : .constant(false)) { providers in
            guard takesFiles else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { attach([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.backing.opacity(0.85)))
                    .overlay(Text(strings(.inputDropFiles)).font(theme.smallFont).foregroundStyle(Color.accentColor))
                    .accessibilityIdentifier("row.input.\(input.id).drop")
            }
        }
        .onAppear(perform: applyFill)
        .onChange(of: input.fill) { _, _ in applyFill() }
    }

    /// The plugin's text put into the field (`InputRow.fill`), once per fill:
    /// after what is typed already, on a line of its own.
    private func applyFill() {
        guard let fill = input.fill, Drafts.shared.filled[key] != fill.id else { return }
        Drafts.shared.filled[key] = fill.id
        let text = fill.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        draft = draft.isEmpty ? text : draft + "\n" + text
    }

    private func attach(_ urls: [URL]) {
        var now = files
        for url in urls where !now.contains(url) { now.append(url) }
        files = Array(now.prefix(Self.mostFiles))
    }

    /// No more files than this go with one message.
    static let mostFiles = 10

    /// A paste of files, or of a picture, attaches it; a paste of text is
    /// the field's.
    private func pasteFiles() -> Bool {
        guard takesFiles, let pasted = PastedFiles.take(from: .general) else { return false }
        attach(pasted)
        return true
    }

    private func chooseFiles() {
        attach(FilePicker.files(prompt: strings(.inputAttach)))
    }

    /// The files above the text: a picture by its thumbnail, any other by its
    /// icon, each with ✕.
    @ViewBuilder
    private var attachments: some View {
        if takesFiles, !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(files.enumerated()), id: \.element) { index, url in
                        HStack(spacing: 5) {
                            // A click opens it — and the field's others — in Quick Look.
                            Button { QuickLook.shared.show(files, at: index) } label: {
                                HStack(spacing: 5) {
                                    Image(nsImage: PastedFiles.thumbnail(of: url))
                                        .resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(url.lastPathComponent).font(theme.smallFont).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: 160, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(url.path)
                            .accessibilityIdentifier("row.input.\(input.id).file.\(index).open")
                            Button { files = files.filter { $0 != url } } label: {
                                // The whole square takes the click, not only the glyph's lines.
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                    .frame(width: 16, height: 16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(strings(.inputRemoveFile))
                            .accessibilityIdentifier("row.input.\(input.id).file.\(index).remove")
                        }
                        .foregroundStyle(theme.text)
                        .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.subtleFill))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("row.input.\(input.id).file.\(index)")
                    }
                }
            }
        }
    }

    private var attachButton: some View {
        Button(action: chooseFiles) {
            Image(systemName: "paperclip").font(.system(size: 12))
                .frame(width: 24, height: 24)
                // The whole square takes the click: a paperclip is thin lines
                // (lab run 45601824620: a click in its middle did nothing).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.muted)
        .help(strings(.inputAttach))
        .accessibilityIdentifier("row.input.\(input.id).attach")
    }

    /// The text: grows to `lines` lines, then scrolls inside (`MessageEditor`).
    private func field(lines: Int) -> some View {
        MessageEditor(text: draftBinding, placeholder: input.placeholder ?? "",
                      font: .systemFont(ofSize: theme.textSize), textColor: NSColor(theme.text),
                      placeholderColor: NSColor(theme.muted), enabled: input.enabled != false, maxLines: lines,
                      identifier: "row.input.\(input.id)", onSubmit: submit,
                      onEscape: input.stop.map { stop in { send(.press(id: stop)) } },
                      onPasteFiles: pasteFiles,
                      onCaret: suggest == nil ? nil : { text, caret in typed(text, caret: caret) },
                      onSuggestKey: suggest == nil ? nil : { key in suggestKey(key) },
                      onShortcut: suggest == nil ? nil : { files in openSuggestions(searched: files) },
                      menuItems: (suggest?.tabs ?? []).map { tab in
                          (title: tab.title + "…", action: { openSuggestions(tab: tab.id) })
                      },
                      handle: handle)
    }

    // MARK: - Suggestions

    /// The «/» by the field: opens the suggestions, or closes them.
    @ViewBuilder
    private var suggestButton: some View {
        if suggest != nil {
            Button {
                if suggesting.open { suggesting.close() } else { openSuggestions() }
            } label: {
                Text("/").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(suggesting.open ? Color.accentColor.opacity(0.3) : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
            .help(strings(.suggestOpen))
            .accessibilityIdentifier("row.input.\(input.id).suggest")
        }
    }

    /// Opened without typing — the button, ⌘/, the menu: on a tab, with a
    /// search of the list's own.
    private func openSuggestions(tab: String? = nil, searched: Bool = false) {
        guard let suggest else { return }
        suggesting.close()
        suggesting.searching = true
        suggesting.tab = tab ?? (searched ? suggest.tabs.first { $0.search == true }?.id : nil)
        if suggesting.tab == nil, suggest.tabs.filter({ $0.search != true }).count <= 1 {
            suggesting.tab = suggest.tabs.first { $0.search != true }?.id ?? suggest.tabs.first?.id
        }
        suggesting.open = true
    }

    /// The text or the caret moved: a trigger before the caret opens the
    /// list on its tabs, and what follows it is the query; without one, a
    /// list a trigger opened closes.
    private func typed(_ text: String, caret: Int) {
        guard let suggest else { return }
        let token = Suggestions.token(in: text, caret: caret, tabs: suggest.tabs)
        if let token {
            if suggesting.dismissedAt == token.range.location { return }
            suggesting.dismissedAt = nil
            if !suggesting.open || suggesting.searching || suggesting.token?.trigger != token.trigger {
                suggesting.close()
                suggesting.scope = token.tabs
                suggesting.tab = token.tabs.count == 1 ? token.tabs[0] : nil
            }
            suggesting.token = token
            suggesting.query = token.query
            suggesting.open = true
        } else {
            suggesting.dismissedAt = nil
            if suggesting.open, !suggesting.searching { suggesting.close() }
        }
    }

    /// A key from the field, the list's while it is open.
    private func suggestKey(_ key: SuggestKey) -> Bool {
        guard let suggest, suggesting.open else { return false }
        return SuggestList.key(key, suggest, suggesting, pick: pick)
    }

    /// A suggestion picked: its text into the field — in place of the
    /// trigger typed, or at the caret — and the list closed.
    private func pick(_ item: SuggestItem) {
        let atStart = suggest?.tabs.first { $0.id == item.tab }?.start == true
        let caret = handle.caret ?? (draft as NSString).length
        let result = Suggestions.insert(item, into: draft, caret: caret, token: suggesting.token, atStart: atStart)
        suggesting.close()
        if handle.view != nil {
            handle.apply(result.text, caret: result.caret)
        } else {
            draft = result.text
        }
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 6) {
            attachments
            HStack(spacing: 6) {
            if takesFiles { attachButton }
            suggestButton
            field(lines: 6)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.backing))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
            if let stop = input.stop {
                ProgressView().controlSize(.small)
                Button { send(.press(id: stop)) } label: { Image(systemName: "stop.fill") }
                    .controlSize(.small)
                    .accessibilityIdentifier("row.input.\(input.id).stop")
            }
            }
        }
    }

    /// The field as a panel: the text on top; the menus, Stop and Send under
    /// it.
    private func panel(_ pickers: [CardMenu]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            attachments
            field(lines: 8)
            HStack(spacing: 6) {
                if takesFiles { attachButton }
                suggestButton
                ForEach(Array(pickers.enumerated()), id: \.offset) { index, picker in
                    MenuPill(menu: picker, row: input.id, theme: theme, send: send)
                        .layoutPriority(Double(-index))
                }
                Spacer(minLength: 4)
                if let stop = input.stop {
                    // Something runs while there is a Stop: said where the eye
                    // is, by the field, not only in a badge above.
                    ProgressView().controlSize(.small).accessibilityIdentifier("row.input.\(input.id).busy")
                    Button { send(.press(id: stop)) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(theme.subtleFill))
                    }
                    .buttonStyle(.plain)
                    .help(strings(.inputStop))
                    .accessibilityIdentifier("row.input.\(input.id).stop")
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.accentColor.opacity(canSend ? 1 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(strings(.inputSend))
                .accessibilityIdentifier("row.input.\(input.id).send")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.backing))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
    }

    private var canSend: Bool {
        input.enabled != false
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (takesFiles && !files.isEmpty))
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = takesFiles ? files : []
        guard !text.isEmpty || !sent.isEmpty, input.enabled != false else { return }
        draft = ""
        files = []
        suggesting.close()
        send(.submit(row: input.id, text: text, files: sent.map(\.path)))
    }
}

/// A `bar` row: a title, menus, tags, badges and buttons on one line; what
/// follows a spacer sits at the right edge. The title gives way first when
/// the card is narrow.
struct BarRowView: View {
    let bar: BarRow
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.drawn(bar.items).enumerated()), id: \.offset) { _, item in
                switch item {
                case .titledMenu(let title, let menu):
                    TitleMenu(title: title, menu: menu, row: bar.id, theme: theme, send: send)
                        .layoutPriority(-1)
                case .item(.title(let title)):
                    HStack(spacing: 7) {
                        if let tone = title.tone { Circle().fill(BarStyle.color(tone, theme)).frame(width: 7, height: 7) }
                        Text(title.text).font(theme.bodyFont.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    }
                    .foregroundStyle(theme.text)
                    .layoutPriority(-1)
                case .item(.tag(let text)):
                    Text(text).font(theme.smallFont).foregroundStyle(theme.muted).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line, lineWidth: 1))
                        .fixedSize()
                case .item(.badge(let badge)):
                    // One with shorter forms takes the width there is and picks
                    // the form that fits it; one without is as wide as its text.
                    if badge.forms.count > 1 {
                        BadgeView(badge: badge, theme: theme).layoutPriority(1)
                    } else {
                        BadgeView(badge: badge, theme: theme).fixedSize()
                    }
                case .item(.menu(let menu)):
                    MenuPill(menu: menu, row: bar.id, theme: theme, send: send, plain: true)
                case .item(.button(let button)):
                    BarButtonView(button: button, row: bar.id, theme: theme, send: send)
                case .item(.spacer):
                    Spacer(minLength: 4)
                case .item(.unsupported):
                    EmptyView()
                }
            }
        }
        // Its items keep identifiers of their own: one set on the stack alone
        // would be given to every control in it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row.bar.\(bar.id)")
    }

    /// What is drawn: the items, a `title` followed at once by a `menu` made
    /// one — the whole title opens the menu (0.9.14). It was the 8 pt
    /// chevron alone, and the operator kept aiming at it (11-25).
    enum Drawn {
        case item(BarItem)
        case titledMenu(BarTitle, CardMenu)
    }

    static func drawn(_ items: [BarItem]) -> [Drawn] {
        var drawn: [Drawn] = []
        var index = 0
        while index < items.count {
            if case .title(let title) = items[index], index + 1 < items.count, case .menu(let menu) = items[index + 1] {
                drawn.append(.titledMenu(title, menu))
                index += 2
            } else {
                drawn.append(.item(items[index]))
                index += 1
            }
        }
        return drawn
    }
}

/// A bar's title that opens the menu after it: its dot, its name and the
/// chevron, one button, lit while the pointer is on it.
struct TitleMenu: View {
    let title: BarTitle
    let menu: CardMenu
    let row: String
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if let tone = title.tone { Circle().fill(BarStyle.color(tone, theme)).frame(width: 7, height: 7) }
                Text(title.text).font(theme.bodyFont.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(theme.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? theme.selection
                : hovering ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("row.menu.\(menu.id)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OptionList(options: menu.options, selected: menu.selected, note: menu.note, prefix: "row.menu.\(menu.id)",
                       theme: theme, press: { send(.press(id: $0)) }) { option in
                open = false
                send(.choose(row: row, menu: menu.id, option: option))
            }
        }
    }
}

/// Colours and symbols for tones and bar icons.
enum BarStyle {
    static func color(_ tone: CardTone, _ theme: DeckTheme) -> Color {
        switch tone {
        case .run, .ok: theme.ok
        case .wait, .warn: theme.warn
        case .crit: theme.crit
        case .info: Color.accentColor
        case .idle: theme.dim
        }
    }

    static func symbol(_ icon: BarIcon) -> String {
        switch icon {
        case .plus: "plus"
        case .history: "clock.arrow.circlepath"
        case .folder: "folder"
        case .model: "sparkle"
        case .effort: "speedometer"
        case .account: "person.crop.circle"
        case .gear: "gearshape"
        case .run: "arrow.triangle.2.circlepath"
        case .wait: "bubble.left"
        case .done: "checkmark"
        case .idle: "moon"
        case .info: "info.circle"
        }
    }

    @ViewBuilder
    static func icon(_ icon: BarIcon, _ size: CGFloat = 10) -> some View {
        if icon == .run {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: size + 2, height: size + 2)
        } else {
            Image(systemName: symbol(icon)).font(.system(size: size, weight: .medium))
        }
    }
}

/// A small tinted pill; with `fill`, it fills from the left like a battery.
struct BadgeView: View {
    let badge: BarBadge
    let theme: DeckTheme

    var body: some View {
        let tone = badge.tone.map { BarStyle.color($0, theme) } ?? theme.muted
        HStack(spacing: 5) {
            if badge.busy == true {
                BusyGlyph(size: theme.textSize - 1.5,
                          color: NSColor(badge.tone == nil || badge.tone == .idle ? theme.muted : theme.text))
            }
            if let icon = badge.icon { BarStyle.icon(icon) }
            let forms = badge.forms
            if forms.count > 1 {
                // The longest form that fits; the last, cut short, when none does.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(forms.enumerated()), id: \.offset) { index, form in
                        if index < forms.count - 1 {
                            Text(form).lineLimit(1).monospacedDigit().fixedSize()
                        } else {
                            Text(form).lineLimit(1).monospacedDigit().truncationMode(.tail)
                        }
                    }
                }
            } else {
                Text(badge.text).lineLimit(1).monospacedDigit()
            }
        }
        .font(theme.smallFont)
        .foregroundStyle(badge.tone == nil || badge.tone == .idle ? theme.muted : theme.text)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .frame(minWidth: badge.fill == nil ? nil : 96, alignment: .leading)
        .background(
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(badge.fill == nil ? tone.opacity(0.18) : theme.subtleFill)
                    if let fill = badge.fill {
                        Rectangle().fill(tone.opacity(0.42)).frame(width: geometry.size.width * fill)
                    }
                }
                .clipShape(Capsule())
            }
        )
    }
}

/// The ✻ of a badge that is `busy`, turning through the glyphs a terminal's
/// agent turns through while it works; still for Reduce Motion.
///
/// Drawn by AppKit on a timer, which runs whatever SwiftUI redraws. Measured
/// turning in lab 45993518051: five different glyphs in seven shots over two
/// seconds, with the guest's Reduce Motion off — the lab's guest has it on,
/// and there the ✻ stands still, as it should.
struct BusyGlyph: NSViewRepresentable {
    let size: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> BusyGlyphView { BusyGlyphView() }

    func updateNSView(_ view: BusyGlyphView, context: Context) {
        view.font = .systemFont(ofSize: size)
        view.color = color
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BusyGlyphView, context: Context) -> CGSize? {
        CGSize(width: ceil(size * 0.95), height: ceil(size * 1.25))
    }
}

final class BusyGlyphView: NSView {
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    var font = NSFont.systemFont(ofSize: 11)
    var color = NSColor.labelColor
    private(set) var index = 4
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 0.12, target: self, selector: #selector(turn), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func turn() {
        index = (index + 1) % Self.frames.count
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyph = NSAttributedString(string: Self.frames[index], attributes: [.font: font, .foregroundColor: color])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func setAccessibilityElement(_ isElement: Bool) {}
    override func isAccessibilityElement() -> Bool { false }
}

/// A menu drawn as a small pill (or plain text and a chevron, on a bar):
/// pressing it opens its options in a popover — grouped under their `group`,
/// the selected one checked, the note last. Drawn by uDeck rather than as a
/// system menu, whose button drops the pill's look.
struct MenuPill: View {
    let menu: CardMenu
    let row: String
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void
    var plain = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if let icon = menu.icon { BarStyle.icon(icon) }
                if !menu.text.isEmpty { Text(menu.text).lineLimit(1).truncationMode(.tail) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(theme.smallFont)
            .foregroundStyle(plain ? theme.muted : theme.text)
            .padding(.horizontal, plain ? 3 : 9).padding(.vertical, plain ? 2 : 4)
            .background(Capsule().fill(plain ? Color.clear : (open ? theme.selection : theme.subtleFill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: plain, vertical: true)
        .accessibilityIdentifier("row.menu.\(menu.id)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OptionList(options: menu.options, selected: menu.selected, note: menu.note, prefix: "row.menu.\(menu.id)",
                       theme: theme, press: { send(.press(id: $0)) }) { option in
                open = false
                send(.choose(row: row, menu: menu.id, option: option))
            }
        }
    }
}

/// What is typed into cards' fields, kept outside the views that show them:
/// the panel's content goes when the panel collapses, and the text did with
/// it — an application switched to, the cursor leaving a held panel — so the
/// panel came back whole with its field empty.
@MainActor @Observable
final class Drafts {
    static let shared = Drafts()
    var texts: [String: String] = [:]
    /// The files going with each field's message (`InputRow.files`).
    var files: [String: [URL]] = [:]
    /// The fill each field had last (`InputRow.fill`), by its id: not put
    /// there again.
    var filled: [String: String] = [:]
}

/// What a paste brings for a field that takes files: the files copied in the
/// Finder, or a picture — a screenshot copied to the clipboard — written to a
/// file of its own. Nil for anything else: that paste is text, the field's.
@MainActor
enum PastedFiles {
    static func take(from pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        let types = pasteboard.types ?? []
        // Text with a picture in it (a web page, a document) pastes as text.
        guard !types.contains(.string), types.contains(.png) || types.contains(.tiff),
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let url = write(picture: data) else { return nil }
        return [url]
    }

    /// Where pasted pictures are written: a folder of uDeck's in the
    /// temporary one, a week's worth kept.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("uDeck pasted", isDirectory: true)
    }

    static func write(picture data: Data) -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for old in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < weekAgo {
            try? manager.removeItem(at: old)
        }
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var url = folder.appendingPathComponent("Pasted \(stamp.string(from: Date())).png")
        var copy = 2
        while manager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Pasted \(stamp.string(from: Date())) \(copy).png")
            copy += 1
        }
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// A picture's own small copy, or the file's icon.
    static func thumbnail(of url: URL) -> NSImage {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The files the person chooses with 📎, in an Open dialog above the panel —
/// at the panel's own level it opened under it (the folder picker, 0.9.5).
@MainActor
enum FilePicker {
    static func files(prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = prompt
        return AboveThePanel.runModal(panel) { panel.runModal() } == .OK ? panel.urls : []
    }
}

/// Whether one of the cards' popovers is open, or closed a moment ago: a
/// click made in one is a choice in uDeck, wherever the popover's window lies
/// and whichever process draws it, and never a click past the panel
/// (`PanelController.handleClickOutside`).
@MainActor
enum PopoverPresence {
    static var closedAt: TimeInterval = 0

    /// A click whose button went down at `wentDown` (system uptime) was made
    /// while a popover was open, or within the moment it takes to close.
    ///
    /// Open is asked of the windows, not counted: a count of appearances and
    /// disappearances stayed above nought once a popover went with the panel
    /// without saying so, and every click past the panel was then taken for
    /// one at a popover — the panel would not close (0.9.8, the operator's
    /// «нажимаю на пустое место, а ничего не происходит»).
    static func holds(at wentDown: TimeInterval) -> Bool {
        isOpen || wentDown - closedAt < 0.8
    }

    /// Whether a popover of uDeck's is on the screen now.
    static var isOpen: Bool {
        NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }
}

/// A menu's options as uDeck draws them in a popover.
struct OptionList: View {
    let options: [MenuOption]
    let selected: String?
    let note: String?
    let prefix: String
    let theme: DeckTheme
    /// An option's button pressed (`MenuOptionButton`): its id, the list left
    /// open. Nil where nothing could be sent — the place menu, uDeck's own.
    var press: ((String) -> Void)? = nil
    let choose: (String) -> Void

    var body: some View {
        let groups = options.reduce(into: [(String?, [MenuOption])]()) { result, option in
            if let last = result.last, last.0 == option.group { result[result.count - 1].1.append(option) }
            else { result.append((option.group, [option])) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if let title = group.0, !title.isEmpty {
                        Text(title).font(theme.smallFont).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, index == 0 ? 2 : 8).padding(.bottom, 2)
                    }
                    ForEach(group.1, id: \.id) { option in
                        HStack(spacing: 2) {
                            OptionRow(option: option, chosen: option.id == selected, theme: theme) { choose(option.id) }
                                .accessibilityIdentifier("\(prefix).\(option.id)")
                            if let button = option.button, let press {
                                OptionButtonView(button: button, theme: theme) { press(button.id) }
                                    .accessibilityIdentifier("\(prefix).\(option.id).button")
                            }
                        }
                    }
                }
                if let note, !note.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text(note).font(theme.smallFont).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.bottom, 2)
                }
            }
            .padding(6)
        }
        .frame(minWidth: 200, maxWidth: 300, maxHeight: 420)
        .fixedSize(horizontal: false, vertical: options.count < 14)
        .onDisappear { PopoverPresence.closedAt = ProcessInfo.processInfo.systemUptime }
    }
}

/// The small button at an option's end: `✕` to close a session from the list
/// of them. Pressed, it sends `press` and leaves the list open.
private struct OptionButtonView: View {
    let button: MenuOptionButton
    let theme: DeckTheme
    let press: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: press) {
            Text(button.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? theme.text : theme.muted)
                .frame(minWidth: 22, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(button.label)
    }
}

private struct OptionRow: View {
    let option: MenuOption
    let chosen: Bool
    let theme: DeckTheme
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                if let tone = option.tone {
                    Circle().fill(BarStyle.color(tone, theme)).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.text).lineLimit(1).truncationMode(.tail)
                    if let note = option.note, !note.isEmpty {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if chosen { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.18)
                : hovering ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct BarButtonView: View {
    let button: BarButton
    let row: String
    let theme: DeckTheme
    let send: (ResidentEvent) -> Void
    @State private var open = false

    var body: some View {
        Button {
            if let options = button.options, !options.isEmpty { open.toggle() } else { send(.press(id: button.id)) }
        } label: { face }
            .buttonStyle(.plain)
            .help(button.note ?? "")
            .accessibilityIdentifier("row.button.\(button.id)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                OptionList(options: button.options ?? [], selected: nil, note: button.note,
                           prefix: "row.button.\(button.id)", theme: theme, press: { send(.press(id: $0)) }) { option in
                    open = false
                    send(.choose(row: row, menu: button.id, option: option))
                }
            }
    }

    private var face: some View {
        HStack(spacing: 4) {
            if let icon = button.icon { BarStyle.icon(icon, 12) }
            if let label = button.label { Text(label).lineLimit(1) }
        }
        .font(theme.smallFont)
        .foregroundStyle(theme.muted)
        .frame(minWidth: 24, minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(open ? theme.subtleFill : Color.clear))
        .contentShape(Rectangle())
    }
}

extension Card {
    /// A bar the card opens with: drawn as the window's title line, in place
    /// of the name, so a card that names itself does not spend a line on it.
    var leadingBar: BarRow? {
        if case .bar(let bar)? = rows.first { bar } else { nil }
    }

    /// Whether the card holds a conversation, which takes the window's room.
    var hasFeed: Bool {
        rows.contains { if case .feed = $0 { true } else { false } }
    }
}

/// A scroll view that starts at its bottom, and otherwise lays out as any:
/// where the system can say so (macOS 15), for the first offset only.
private struct StartsAtTheBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}
