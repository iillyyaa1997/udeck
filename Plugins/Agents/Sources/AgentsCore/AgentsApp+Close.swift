import Foundation
import UDeckAgents

/// Closing a session (11-25): ✕ in the title line closes the one shown, ✕ by
/// a session in the menu closes that one. Its CLI ends; the conversation stays
/// in that CLI's history, to continue from the menu. Every ✕ asks first, in
/// the place it was pressed in, naming the session.
extension AgentsApp {
    /// ✕ pressed for `id`: the card here asks.
    func askToClose(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        confirmingClose = id
    }

    /// Ends the session's CLI and takes it off the list; a place that showed
    /// it shows another one, or none.
    func closeSession(_ id: UUID) {
        for name in places.keys where places[name]?.confirmingClose == id { places[name]?.confirmingClose = nil }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        forget(id)
        Task {
            for agent in conversation.agents.values { await agent.close() }
            refreshHistory()
            render()
        }
    }

    /// The question asked before a session is closed: «Stop and close» for
    /// one in a turn, «Close» for the rest.
    func closeAskRow(_ session: Conversation) -> JSONValue {
        let working = session.current.state == .working
        let name = "«" + session.title + "»"
        let title = working
            ? t(name + " сейчас работает — остановить и закрыть?", name + " is working — stop it and close it?")
            : t("Закрыть " + name + "?", "Close " + name + "?")
        let detail = working
            ? t("Ход остановится на середине. Разговор останется в истории",
                "The turn stops where it is. The conversation stays in the history")
            : t("Разговор останется в истории — его можно продолжить",
                "The conversation stays in the history, to continue later")
        return ["id": .string("close-" + session.id.uuidString), "title": .string(title), "detail": .string(detail),
                "buttons": [
                    ["id": .string("closenow:" + session.id.uuidString),
                     "label": .string(working ? t("Остановить и закрыть", "Stop and close") : t("Закрыть", "Close")),
                     "primary": true],
                    ["id": .string("keepopen:" + session.id.uuidString), "label": .string(t("Оставить", "Keep it"))],
                ]]
    }

    /// The presses closing is made of; false for any other.
    func pressClose(_ id: String) -> Bool {
        if id == "close" {
            if let selected { askToClose(selected.id) }
            return true
        }
        for (prefix, act) in [("close:", askToClose), ("closenow:", closeSession)] as [(String, (UUID) -> Void)] {
            if id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) {
                act(uuid)
                return true
            }
        }
        if id.hasPrefix("keepopen:") {
            confirmingClose = nil
            return true
        }
        return false
    }
}
