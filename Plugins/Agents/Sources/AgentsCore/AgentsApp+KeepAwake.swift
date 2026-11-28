import Foundation
import UDeckAgents

/// The Mac kept awake while an agent works (`KeepAwake`), and a sleep said in
/// the feed of each session it stopped.
extension AgentsApp {
    /// Setting `keep_awake`, a bool: on unless switched off.
    var keepAwakeEnabled: Bool {
        settings.bool("keep_awake", true)
    }

    /// The sessions in a turn and not waiting for the person.
    var workingSessions: Set<UUID> {
        Set(conversations.filter { $0.current.state == .working && $0.current.waiting == 0 }.map(\.id))
    }

    /// Holds or lets go, as the sessions are now.
    func updateKeepAwake() {
        // In English whatever the language: powerd keeps an assertion's name
        // in ASCII, and `pmset -g assertions` showed a Russian one as "".
        keepAwake.update(working: workingSessions, enabled: keepAwakeEnabled,
                         name: "uDeck Agents: an agent is working")
    }

    /// Looks for a sleep every half a minute, and asks again who else holds
    /// the Mac.
    func watchSleep() {
        guard sleepLoop == nil else { return }
        sleepLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.lookForASleep()
            }
        }
    }

    func lookForASleep() {
        if let slept = keepAwake.look(working: workingSessions), !slept.stopped.isEmpty {
            let note = sleptNote(from: slept.from, to: slept.to)
            for conversation in conversations where slept.stopped.contains(conversation.id) {
                conversation.current.note(note)
            }
        }
        keepAwake.refreshOthers()
        render()
    }

    /// «💤 Мак спал 45 мин (01:20–02:05) — агент стоял».
    func sleptNote(from: Date, to: Date) -> String {
        let minutes = max(1, Int((to.timeIntervalSince(from) / 60).rounded()))
        let length = minutes < 60
            ? t("\(minutes) мин", "\(minutes) min")
            : t("\(minutes / 60) ч", "\(minutes / 60) h") + (minutes % 60 == 0 ? "" : t(" \(minutes % 60) мин", " \(minutes % 60) min"))
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        let span = format.string(from: from) + "–" + format.string(from: to)
        return t("💤 Мак спал \(length) (\(span)) — агент стоял", "💤 The Mac slept \(length) (\(span)) — the agent stood still")
    }

    /// The card's line while the Mac is held: how many work, who else holds
    /// it, and that a lid closes it anyway.
    /// ☕ in the card's line, what it means on a click — the operator's
    /// choice over two lines that came and went (11-28; setting `sleep_show`).
    func keepAwakeBadge() -> JSONValue? {
        guard keepAwake.holding, settings.sleepShown == "icon" else { return nil }
        return ["text": "☕", "details": .array(keepAwakeLines(split: true))]
    }

    func keepAwakeRows() -> [JSONValue] {
        guard keepAwake.holding else { return [] }
        switch settings.sleepShown {
        case "two": return keepAwakeLines(split: true)
        case "one": return keepAwakeLines(split: false)
        default: return []
        }
    }

    /// What keeps the Mac awake: one line, or the session's and the rest.
    private func keepAwakeLines(split: Bool) -> [JSONValue] {
        let count = keepAwake.working
        let line = t("☕ Мак не уснёт, пока \(count == 1 ? "работает" : "работают") \(count) \(Self.sessions(count))",
                     "☕ The Mac stays awake while \(count) session\(count == 1 ? "" : "s") work\(count == 1 ? "s" : "")")
        var rows: [JSONValue] = [["text": .string(line)]]
        var more: [String] = []
        if !keepAwake.others.isEmpty {
            more.append(t("Ещё не дают спать: ", "Also keeping it awake: ") + keepAwake.others.joined(separator: ", "))
        }
        if keepAwake.hasALid { more.append(t("Закроешь крышку — уснёт всё равно", "Close the lid and it sleeps anyway")) }
        guard !more.isEmpty else { return rows }
        if split { rows.append(["text": .string(more.joined(separator: " · "))]) } else {
            rows = [["text": .string(([line] + more).joined(separator: " · "))]]
        }
        return rows
    }

    nonisolated static func sessions(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: "сессия"
        case 2...4 where !(12...14).contains(count % 100): "сессии"
        default: "сессий"
        }
    }
}
