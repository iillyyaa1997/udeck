import AppKit
import SwiftUI
import UDeckAgents
import UDeckChat
import UDeckCore

/// An account as the chat names it: the main one in the user's language, the
/// rest by their folder's suffix (`~/.claude-pers2` → pers2).
func accountName(_ account: ChatAccount, _ strings: () -> Strings) -> String {
    account.configDir == nil ? strings()(.chatMainAccount) : account.name
}

/// The chat window: open sessions and History on the left, the chosen session
/// on the right.
struct ChatRootView: View {
    @Bindable var store: ChatStore
    let strings: () -> Strings

    var body: some View {
        NavigationSplitView {
            ChatSidebar(store: store, strings: strings)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let session = store.selected {
                SessionView(session: session, strings: strings, onClose: { store.close(session) })
                    .id(session.id)
            } else {
                Text(strings()(.chatNothingOpen))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.refreshHistory() }
    }
}

struct ChatSidebar: View {
    @Bindable var store: ChatStore
    let strings: () -> Strings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                chooseFolder()
            } label: {
                Label(strings()(.chatNewSession), systemImage: "plus.bubble")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chat.newSession")
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if store.accounts.count > 1 {
                Picker(strings()(.chatAccount), selection: $store.account) {
                    ForEach(store.accounts) { account in Text(accountName(account, strings)).tag(account) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("chat.account")
            }

            List(selection: $store.selection) {
                if !store.sessions.isEmpty {
                    Section(strings()(.chatSessions)) {
                        ForEach(store.sessions) { session in
                            SessionRow(session: session, strings: strings).tag(session.id)
                        }
                    }
                }
                Section(strings()(.chatHistory)) {
                    if store.history.isEmpty {
                        Text(strings()(store.loadingHistory ? .chatLoadingHistory : .chatNoHistory))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.history) { saved in
                        Button {
                            store.open(saved)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.title).lineLimit(1)
                                Text(historySubtitle(saved)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func historySubtitle(_ saved: SavedSession) -> String {
        let folder = saved.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let when = saved.modified.formatted(.relative(presentation: .named))
        return folder.isEmpty ? when : "\(folder) · \(when)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = strings()(.chatChooseFolder)
        if panel.runModal() == .OK, let folder = panel.url {
            store.newSession(in: folder)
        }
    }
}

struct SessionRow: View {
    let session: ChatSession
    let strings: () -> Strings

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text("\(session.folder.lastPathComponent) · \(accountName(session.account, strings))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !session.asks.isEmpty {
                Spacer()
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            }
        }
    }

    private var dotColor: Color {
        if !session.asks.isEmpty { return .orange }
        switch session.state {
        case .working: return .blue
        case .idle: return .green
        case .starting: return .gray
        case .ended: return .secondary
        }
    }
}

/// One session: its feed, what it waits on the user for, and the input.
struct SessionView: View {
    let session: ChatSession
    let strings: () -> Strings
    let onClose: () -> Void
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.items) { item in
                            FeedRow(item: item, strings: strings).id(item.id)
                        }
                        ForEach(session.asks) { ask in
                            AskCard(ask: ask, strings: strings) { session.answer(ask, with: $0) }
                                .id("ask-" + ask.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: session.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.asks.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: lastText) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            input
        }
        .onExitCommand { session.interrupt() }
        .onAppear { inputFocused = true }
    }

    /// Follows the streaming answer as it grows.
    private var lastText: String {
        if case .assistant(_, let text, true)? = session.items.last { return text }
        return ""
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline).lineLimit(1)
                Text(session.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("chat.status")
            Text(accountName(session.account, strings))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(strings()(.chatCloseSession))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch session.state {
        case .starting: return strings()(.chatStarting)
        case .working:
            return session.pendingTurns > 1 ? strings()(.chatQueued(count: session.pendingTurns - 1))
                : strings()(.chatWorking)
        case .idle: return session.model ?? ""
        case .ended(let reason): return strings()(.chatEnded) + (reason.isEmpty ? "" : " — \(reason)")
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(strings()(.chatPlaceholder), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(session.isEnded)
                .accessibilityIdentifier("chat.input")
            if session.state == .working {
                Button(strings()(.chatStop)) { session.interrupt() }
                    .accessibilityIdentifier("chat.stop")
            }
            Button(strings()(.chatSend), action: send)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isEnded)
                .accessibilityIdentifier("chat.send")
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        session.send(text)
    }
}

struct FeedRow: View {
    let item: FeedItem
    let strings: () -> Strings
    @State private var expanded = false

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        case .assistant(_, let text, let streaming):
            Text(markdown(text) + (streaming ? AttributedString(" ▍") : AttributedString()))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let name, let summary, let result):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text(name).fontWeight(.medium)
                        Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if result?.isError == true {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        } else if result == nil {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                }
                .buttonStyle(.plain)
                if expanded, let result {
                    Text(result.preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
            }
        case .note(_, let text):
            Text(text == "resumed" ? strings()(.chatResumed) : text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A permission or a question, answered with buttons.
struct AskCard: View {
    let ask: ChatAsk
    let strings: () -> Strings
    let answer: (ChatSession.Answer) -> Void
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let questions = ask.ask.questions {
                Text(strings()(.chatQuestion)).font(.caption).foregroundStyle(.secondary)
                ForEach(questions, id: \.question) { question in
                    QuestionBlock(question: question, picked: $picked) { label in
                        if questions.count == 1 { answer(.choices([question.question: [label]])) }
                    }
                }
                if questions.count > 1 || questions.contains(where: \.multiSelect) {
                    Button(strings()(.chatSend)) { answer(.choices(picked.mapValues { Array($0) })) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text(strings()(.chatWantsToUse(tool: ask.ask.displayName))).fontWeight(.semibold)
                if !ask.summary.isEmpty {
                    Text(ask.summary)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
                if let reason = ask.ask.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(strings()(.chatAllow)) { answer(.allow) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityIdentifier("chat.ask.allow")
                    if ask.ask.offersAlways {
                        Button(strings()(.chatAllowAlways)) { answer(.allowAlways) }
                            .accessibilityIdentifier("chat.ask.always")
                    }
                    Button(strings()(.chatDeny)) { answer(.deny) }
                        .accessibilityIdentifier("chat.ask.deny")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
    }
}

/// One question of an AskUserQuestion: its options as buttons. A single
/// choice in a lone question answers at once (`chose`); otherwise picks are
/// gathered and sent together.
struct QuestionBlock: View {
    let question: AgentQuestion
    @Binding var picked: [String: Set<String>]
    let chose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question).fontWeight(.semibold)
            HStack {
                ForEach(question.options, id: \.label) { option in
                    optionButton(option)
                }
            }
        }
    }

    private func optionButton(_ option: AgentQuestion.Option) -> some View {
        let chosen = (picked[question.question] ?? []).contains(option.label)
        return Button(option.label) { tap(option.label) }
            .buttonStyle(.bordered)
            .tint(chosen ? Color.accentColor : nil)
            .help(option.description ?? "")
            .accessibilityIdentifier("chat.ask.option." + option.label)
    }

    private func tap(_ label: String) {
        var set = picked[question.question] ?? []
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        picked[question.question] = set
        if !question.multiSelect { chose(label) }
    }
}
