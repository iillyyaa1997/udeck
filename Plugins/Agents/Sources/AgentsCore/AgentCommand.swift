import Foundation
import UDeckAgents

/// A command or a skill an agent has: what the field's «/» suggests (uDeck
/// 0.9.25, the operator's «1» to questions 197–199, 11-27).
public struct AgentCommand: Sendable, Equatable {
    /// Without its «/» or «$».
    public var name: String
    public var description: String
    public var argumentHint: String?
    /// claude marks its own commands and the skills it comes with so.
    public var builtin: Bool
    /// A Codex skill's file, which goes with it in a message.
    public var path: String?

    public init(name: String, description: String, argumentHint: String? = nil, builtin: Bool = false,
                path: String? = nil)
    {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.builtin = builtin
        self.path = path
    }

    /// claude's, from its answer to `initialize`: `commands`, each with
    /// `name`, `description`, `argumentHint` and `builtin`.
    static func claude(_ body: JSONValue) -> [AgentCommand] {
        (body["commands"]?.array ?? []).compactMap { raw in
            guard let name = raw["name"]?.string, !name.isEmpty else { return nil }
            let hint = raw["argumentHint"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return AgentCommand(name: name, description: raw["description"]?.string ?? "", argumentHint: hint,
                                builtin: raw["builtin"]?.bool ?? false)
        }
    }

    /// Codex's, from `skills/list`: the folder's skills that are on.
    static func codex(_ list: JSONValue) -> [AgentCommand] {
        var seen = Set<String>()
        return (list["data"]?.array ?? []).flatMap { $0["skills"]?.array ?? [] }.compactMap { raw in
            guard let name = raw["name"]?.string, !name.isEmpty, raw["enabled"]?.bool != false,
                  seen.insert(name).inserted else { return nil }
            let about = raw["interface"]?["shortDescription"]?.string ?? raw["shortDescription"]?.string
                ?? raw["description"]?.string ?? ""
            return AgentCommand(name: name, description: about, path: raw["path"]?.string)
        }
    }
}

/// What the field suggests in a session, and what the card does itself with
/// what is typed there.
@MainActor
enum AgentsSuggest {
    /// claude's commands that do nothing in a card, or cost money: not
    /// suggested (the operator's «1» to question 199). Typed by hand they
    /// still go.
    static let hidden: Set<String> = [
        "color", "focus", "heapdump", "__remote-workflow", "workflow-launch-exec", "agents", "extra-usage",
        // $5–25 a run, and paid credits.
        "ultrareview", "usage-credits",
    ]

    /// What the card does itself — its menus do the same — so that the card
    /// and the agent do not part ways.
    static let byTheCard: Set<String> = ["model", "effort", "clear", "rename"]

    /// claude's own commands in Russian, by name. What it lists beyond these
    /// is a skill, its own description as it is.
    static let claudeCommands: [String: String] = [
        "model": "сменить модель",
        "effort": "сменить усилие",
        "clear": "новый чат в этой папке, этот останется в списке",
        "rename": "переименовать чат",
        "compact": "сжать разговор, освободить контекст",
        "context": "сколько занято контекста",
        "usage": "расход и лимиты",
        "init": "создать CLAUDE.md для проекта",
        "mcp": "MCP-серверы: переподключить, включить, выключить",
        "goal": "работать, пока не выполнено условие",
        "fast": "быстрый режим: вкл или выкл",
        "advisor": "советоваться с более сильной моделью",
        "recap": "итог сессии одной строкой",
        "debug": "журнал отладки и разбор проблемы",
        "design": "доступ агента к проектам Claude Design",
        "design-consent": "дать доступ к проектам Claude Design",
        "design-revoke": "забрать доступ к проектам Claude Design",
        "auto-mode-setup": "настроить авто-режим под это окружение",
        "autocompact": "когда сжимать разговор самому",
        "config": "поменять настройку: ключ=значение",
        "output-style": "стиль ответов: список или выбрать",
        "import": "перенести настройки другого агента",
        "reload-plugins": "подхватить изменения плагинов",
        "reload-skills": "подхватить скилы, изменённые на диске",
        "security-review": "проверка безопасности изменений в ветке",
        "insights": "отчёт по твоим сессиям",
        "skill-doctor": "какие скилы не используются и занимают контекст",
        "list-agents": "другие агенты и сессии, которым можно написать",
        "team-onboarding": "гайд для коллег по твоему опыту",
    ]

    /// Codex's commands — the card's, as the protocol has no text command.
    static let codexCommands: [(name: String, russian: String, english: String)] = [
        ("model", "сменить модель", "change the model"),
        ("effort", "сменить усилие", "change the effort"),
        ("compact", "сжать разговор, освободить контекст", "sum the thread up, freeing its context"),
        ("review", "ревью того, что не закоммичено", "review what is not committed"),
        ("new", "новый чат в этой папке", "a new chat in this folder"),
        ("rename", "переименовать чат", "rename the chat"),
    ]

    /// The tabs: commands and skills on «/» at the start, files on «@».
    static func tabs(_ app: AgentsApp) -> [JSONValue] {
        [["id": "commands", "title": .string(app.t("Команды", "Commands")), "trigger": "/", "start": true],
         ["id": "skills", "title": .string(app.t("Скилы", "Skills")), "trigger": "/", "start": true],
         ["id": "files", "title": .string(app.t("Файлы", "Files")), "trigger": "@", "search": true]]
    }

    /// The items of a session: its commands, then its skills.
    static func items(_ agent: Agent, _ app: AgentsApp) -> [JSONValue] {
        switch agent {
        case .claude(let session):
            var commands: [JSONValue] = []
            var skills: [JSONValue] = []
            for command in session.commands where !hidden.contains(command.name) {
                if let russian = claudeCommands[command.name] {
                    let about = app.russian ? russian : command.description
                    commands.append(item("c:" + command.name, tab: "commands", text: "/" + command.name,
                                         detail: about, hint: command.argumentHint,
                                         note: byTheCard.contains(command.name) ? app.t("карточка", "card") : nil))
                } else {
                    skills.append(item("s:" + command.name, tab: "skills", text: "/" + command.name,
                                       detail: firstSentence(command.description), hint: command.argumentHint))
                }
            }
            // Before claude has said its list: the card's own, at least.
            if session.commands.isEmpty {
                for name in ["model", "effort", "clear", "rename"] {
                    commands.append(item("c:" + name, tab: "commands", text: "/" + name,
                                         detail: app.russian ? claudeCommands[name] ?? "" : name, hint: nil,
                                         note: app.t("карточка", "card")))
                }
            }
            return commands + skills
        case .codex(let session):
            let commands = codexCommands.map { command in
                item("c:" + command.name, tab: "commands", text: "/" + command.name,
                     detail: app.t(command.russian, command.english), hint: nil, note: app.t("карточка", "card"))
            }
            let skills = session.skills.map { skill in
                item("s:" + skill.name, tab: "skills", text: "$" + skill.name, detail: firstSentence(skill.description),
                     hint: nil)
            }
            return commands + skills
        }
    }

    static func item(_ id: String, tab: String, text: String, detail: String, hint: String?, note: String? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "tab": .string(tab), "text": .string(text)]
        let line = [detail, hint ?? ""].filter { !$0.isEmpty }.joined(separator: "  ")
        if !line.isEmpty { item["detail"] = .string(line) }
        if let note { item["note"] = .string(note) }
        return .object(item)
    }

    /// A skill's description is written for the model, often a paragraph:
    /// its first sentence, at most a line and a half.
    static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var end = flat.endIndex
        if let stop = flat.range(of: ". ") { end = stop.lowerBound }
        var sentence = String(flat[..<end])
        if sentence.count > 160 { sentence = String(sentence.prefix(159)) + "…" }
        return sentence
    }

    /// The id of what a message starts with, when it is a suggested command
    /// or skill: for the recent ones.
    static func used(_ text: String, _ agent: Agent) -> String? {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard first.count > 1 else { return nil }
        let name = String(first.dropFirst())
        switch agent {
        case .claude(let session):
            guard first.hasPrefix("/"), let command = session.commands.first(where: { $0.name == name }) else { return nil }
            return (claudeCommands[command.name] != nil ? "c:" : "s:") + name
        case .codex(let session):
            if first.hasPrefix("/"), codexCommands.contains(where: { $0.name == name }) { return "c:" + name }
            if first.hasPrefix("$"), session.skills.contains(where: { $0.name == name }) { return "s:" + name }
            return nil
        }
    }
}
