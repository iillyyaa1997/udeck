import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Names of sessions (11-25): the person's `/rename`, the session's own name,
/// one a model made up after the first answer, the first words said; the
/// history without the sessions programs ran.
@Suite("Names of sessions", .serialized)
@MainActor
struct AgentsNamesTests {
    final class Awake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }

    func app(language: String = "ru") async throws -> (AgentsApp, URL) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-names-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = AgentsApp(home: home, emit: { _ in }, keepAwake: KeepAwake(holder: Awake()))
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"\#(language)"}"#)
        return (app, home)
    }

    /// Sends `text` and allows what the stand-in asks to run: the turn ends.
    func turn(_ text: String, in conversation: Conversation, _ app: AgentsApp) async throws {
        conversation.send(text)
        try await until("the ask") { conversation.current.waiting > 0 }
        let request: String? = switch conversation.current {
        case .claude(let session): session.asks.first?.requestID
        case .codex(let session): session.asks.first?.requestID
        }
        await app.handle(#"{"event":"press","id":"allow:\#(try #require(request))"}"#)
        try await until("the turn's end") { conversation.current.state == .idle && conversation.current.waiting == 0 }
    }

    // MARK: - Words

    @Test("the first words name a session only when they say what it is about")
    func firstWords() {
        #expect(ChatNames.firstWords("1") == nil)
        #expect(ChatNames.firstWords("да") == nil)
        #expect(ChatNames.firstWords("Продолжай.") == nil)
        #expect(ChatNames.firstWords("2 да") == nil, "an option number, then a bare answer")
        #expect(ChatNames.firstWords("/planning-workflow udeck") == nil, "a command")
        #expect(ChatNames.firstWords("<pasted_content id=\"a\">a long log\nmore</pasted_content>\nпочему падает тест?")
                    == "почему падает тест?")
        #expect(ChatNames.firstWords("Минск") == "Минск")
        #expect(ChatNames.firstWords("1 почини кнопку") == "почини кнопку")
        let long = ChatNames.firstWords("Посмотри почему не работает кнопка в настройках после нажатия на неё")
        #expect(long == "Посмотри почему не работает кнопка в настройках…", "cut at a word")
    }

    @Test("a model's answer is taken as a name without quotes, a label or a full stop; a long one is not a name")
    func cleaned() {
        #expect(ChatNames.cleaned("«Кнопка обновления в настройках».") == "Кнопка обновления в настройках")
        #expect(ChatNames.cleaned("Title: Fix the login test\n") == "Fix the login test")
        #expect(ChatNames.cleaned("") == nil)
        #expect(ChatNames.cleaned("I looked at the conversation and I think it is about fixing a flaky test in CI") == nil)
    }

    @Test("a name that starts with continuing or runs long will not do; one that still does not is made to")
    func willNotDo() {
        #expect(ChatNames.willNotDo("Продолжение print-lab: шафл-коробка v3"))
        #expect(ChatNames.willNotDo("Помощь с документами"))
        #expect(ChatNames.willNotDo("Continue the release notes"))
        #expect(ChatNames.willNotDo("Анализ кластера и CI, и решение про второй сервер в Европе"))
        #expect(!ChatNames.willNotDo("Документы для ИП и ВНЖ"))
        #expect(ChatNames.willNotDo("Планирование: u-pilot"))
        #expect(ChatNames.cleaned("подключение маркетплейса к чату") == "Подключение маркетплейса к чату")
        #expect(ChatNames.cleaned("Продолжение print-lab: шафл-коробка v3") == "Шафл-коробка v3")
        #expect(ChatNames.cleaned("Анализ кластера и CI, и решение про второй сервер в Европе") == "Анализ кластера и CI")
    }

    @Test("a model is shown what was pasted, not a skill's text or a bare answer")
    func excerpt() {
        let items: [FeedItem] = [
            .user(id: UUID(), text: "\n\n<pasted_content id=\"05ce\">\n/planning-workflow Продолжаем Warren. Автономный прогон\n</pasted_content>"),
            .user(id: UUID(), text: "1"),
            .assistant(id: UUID(), text: "Читаю план Warren", streaming: false),
        ]
        let excerpt = AgentsApp.excerpt(items)
        #expect(excerpt?.contains("Продолжаем Warren") == true)
        #expect(excerpt?.contains("pasted_content") == false)
        #expect(excerpt?.contains("Person: 1") == false)
        #expect(excerpt?.hasSuffix("Agent: Читаю план Warren") == true)
        #expect(SessionHistory.spoken("Base directory for this skill: /x/workflow-authoring\n# Workflow authoring") == .machine)
        let transcript = ClaudeTranscript(contents: [
            #"{"type":"user","message":{"role":"user","content":"<pasted_content id=\"1\">/planning-workflow Продолжаем Warren</pasted_content>"}}"#,
            ##"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"# Workflow authoring reference"}]}}"##,
        ].joined(separator: "\n"))
        let opening = SessionHistory.feed(of: transcript)
        #expect(opening.count == 1, "a skill's text, put in by Claude Code, is not the person's")
    }

    @Test("the names kept: the person's is not replaced by a model's; the newest are kept")
    func kept() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-names-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var names = ChatNames()
        let news = names.mark("claude:a")
        let again = names.mark("claude:a")
        #expect(news && !again)
        names.name("claude:a", "Мой чат", byPerson: true)
        names.name("claude:a", "Имя от модели", byPerson: false)
        names.save(home: home)
        let read = ChatNames.load(home: home)
        #expect(read.entries["claude:a"]?.named?.0 == "Мой чат")
        #expect(read.entries["claude:a"]?.named?.1 == .person)
        for index in 0..<(ChatNames.kept + 5) { names.mark("codex:\(index)") }
        #expect(names.entries.count == ChatNames.kept)
    }

    // MARK: - The history

    func transcript(_ lines: [String], id: String, in home: URL) throws {
        let folder = home.appendingPathComponent(".claude/projects/-tmp-work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(id + ".jsonl"),
                                                         atomically: true, encoding: .utf8)
    }

    @Test("the history names a session by its own name, else its first words — not by the last thing typed")
    func historyNames() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-names-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try transcript([
            #"{"type":"user","entrypoint":"cli","cwd":"/tmp/work","message":{"role":"user","content":"1"}}"#,
            #"{"type":"user","entrypoint":"cli","cwd":"/tmp/work","message":{"role":"user","content":[{"type":"text","text":"Почини кнопку обновления"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"2"}"#,
        ], id: "first-words", in: home)
        try transcript([
            #"{"type":"custom-title","customTitle":"старое имя","sessionId":"own"}"#,
            #"{"type":"user","entrypoint":"cli","cwd":"/tmp/work","message":{"role":"user","content":"продолжай"}}"#,
            #"{"type":"custom-title","customTitle":"ADR-0025 windows kvm-ci","sessionId":"own"}"#,
            #"{"type":"last-prompt","lastPrompt":"продолжай"}"#,
        ], id: "own", in: home)
        let saved = SessionHistory.recent(config: home.appendingPathComponent(".claude"))
        let byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.sessionID, $0) })
        #expect(byID["first-words"]?.named.0 == "Почини кнопку обновления")
        #expect(byID["first-words"]?.named.1 == .firstWords)
        #expect(byID["own"]?.named.0 == "ADR-0025 windows kvm-ci", "the newest custom-title")
        #expect(byID["own"]?.named.1 == .own)
        #expect(byID["own"]?.folderName == "work")
    }

    @Test("sessions programs ran are not in the history; this plugin's own are")
    func historyWithoutPrograms() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        try transcript([#"{"type":"user","entrypoint":"cli","cwd":"/tmp/work","message":{"role":"user","content":"Почини кнопку"}}"#],
                       id: "by-a-person", in: home)
        try transcript([#"{"type":"user","entrypoint":"sdk-cli","cwd":"/tmp/work","message":{"role":"user","content":"Problem: flow 88d9"}}"#],
                       id: "by-a-script", in: home)
        try transcript([#"{"type":"user","entrypoint":"sdk-cli","cwd":"/tmp/work","message":{"role":"user","content":"Посмотри заметки"}}"#],
                       id: "by-agents", in: home)
        app.names.mark(ChatNames.key(.claude, "by-agents"))
        app.refreshHistory()
        #expect(Set(app.history.map(\.sessionID)) == ["by-a-person", "by-agents"])
        let menu = AgentsCard.sessionMenu(app)["options"]?.array ?? []
        let person = try #require(menu.first { $0["id"]?.string == "h:by-a-person" })
        #expect(person["text"]?.string == "Почини кнопку")
        #expect(person["note"]?.string?.hasPrefix("work · ") == true, "the folder, then when")
    }

    @Test("the history's sessions are named by a model once, over a status line's custom-title")
    func historyNamedByAModel() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(NameSource.model > .own && NameSource.person > .model)
        try transcript([
            #"{"type":"user","entrypoint":"cli","cwd":"/tmp/work","message":{"role":"user","content":"Посмотри заметки в папке [name-me]"}}"#,
            #"{"type":"custom-title","customTitle":"operator skill","sessionId":"status"}"#,
        ], id: "status", in: home)
        app.refreshHistory()
        func shown() -> String? {
            (AgentsCard.sessionMenu(app)["options"]?.array ?? []).first { $0["id"]?.string == "h:status" }?["text"]?.string
        }
        // Named in the background, at a utility priority: under a CI's load of
        // every suite at once it took 7.6 s of a 10 s wait, and then more.
        try await until("the model's name", timeout: .seconds(40)) { shown() == "Осмотр папки с заметками" }
        #expect(ChatNames.load(home: home).entries[ChatNames.key(.claude, "status")]?.name == "Осмотр папки с заметками")
        // Once: the next look asks nothing.
        let tries = app.namingTries
        app.refreshHistory()
        #expect(app.namingTries == tries && app.historyNaming == nil)
    }

    // MARK: - Made up, renamed

    @Test("after the first answer the session's own agent names it: Claude by Haiku, with nothing of the person's")
    func claudeNames() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".claude/fake-claude-log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        try await turn("Посмотри заметки в папке [name-me]", in: conversation, app)
        try await until("the name") { conversation.title == "Осмотр папки с заметками" }
        #expect(conversation.first.titleSource == .model)
        let key = try #require(conversation.first.nameKey)
        #expect(ChatNames.load(home: home).entries[key]?.name == "Осмотр папки с заметками")

        func namingRuns() throws -> [[String]] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .compactMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                .filter { $0.contains("--no-session-persistence") && $0.contains("--tools") }
        }
        let naming = try #require(try namingRuns().first)
        #expect(naming.contains("haiku"))
        #expect(naming.firstIndex(of: "--setting-sources").map { naming[$0 + 1] } == "project", "no hooks of the person's")

        // Once a session: the next turn asks no model again.
        try await turn("и ещё раз [name-me]", in: conversation, app)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try namingRuns().count == 1, "no second naming run")
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a name that will not do is asked for once more: Claude and Codex")
    func askedAgain() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let claude = try #require(app.conversations.first)
        try await until("idle") { claude.current.state == .idle }
        try await turn("Посмотри заметки в папке [name-bad]", in: claude, app)
        try await until("the second name") { claude.title == "Заметки в папке" }
        #expect(claude.first.titleSource == .model)

        await app.newConversation(in: home, provider: .codex)
        let codex = try #require(app.conversations.last)
        try await until("idle") { codex.current.state == .idle }
        try await turn("Fix the notes [name-bad]", in: codex, app)
        try await until("the second name") { codex.title == "Fixing the notes" }
        for conversation in [claude, codex] {
            for agent in conversation.agents.values { await agent.close() }
        }
    }

    @Test("switched off, a session keeps its first words")
    func switchedOff() async throws {
        setenv("UDECK_SETTING_NAME_CHATS", "false", 1)
        defer { unsetenv("UDECK_SETTING_NAME_CHATS") }
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        try await turn("Посмотри заметки в папке [name-me]", in: conversation, app)
        try await Task.sleep(for: .milliseconds(600))
        #expect(conversation.title == "Посмотри заметки в папке [name-me]")
        #expect(conversation.first.titleSource == .firstWords)
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a Codex session is named by Codex, and the thread is given the name")
    func codexNames() async throws {
        let (app, home) = try await app(language: "en")
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .codex)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        try await turn("Fix the notes [name-me]", in: conversation, app)
        try await until("the name") { conversation.title == "Fixing the notes" }
        // Codex says the thread's name back as its own: weaker than the model's, the same words.
        try await Task.sleep(for: .milliseconds(300))
        #expect(conversation.first.titleSource == .model)
        #expect(conversation.title == "Fixing the notes")
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("/rename in the field names the session, over any other name; alone it says how")
    func rename() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        try await turn("Посмотри заметки в папке", in: conversation, app)

        await app.handle(#"{"event":"submit","text":"/rename"}"#)
        #expect(conversation.first.titleSource < .person)
        #expect(conversation.current.items.contains { if case .note(_, "rename-how") = $0 { true } else { false } })

        await app.handle(#"{"event":"submit","text":"/rename  Мой чат "}"#)
        #expect(conversation.title == "Мой чат")
        #expect(conversation.first.titleSource == .person)
        #expect(!conversation.current.items.contains { if case .user(_, let text) = $0 { text.hasPrefix("/rename") } else { false } },
                "not sent to the agent")
        let key = try #require(conversation.first.nameKey)
        #expect(ChatNames.load(home: home).entries[key]?.byPerson == true)
        #expect(!conversation.first.name("Имя от модели", from: .model), "a model's name does not replace it")
        for agent in conversation.agents.values { await agent.close() }
    }
}
