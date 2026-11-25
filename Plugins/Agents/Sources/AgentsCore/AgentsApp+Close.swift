import Foundation
import UDeckAgents

/// Closing a session (11-25): ✕ in the title line closes the one shown, ✕ by
/// a session in the menu closes that one. Its CLI ends; the conversation stays
/// in that CLI's history, to continue from the menu. One in a turn asks first.
extension AgentsApp {
    /// ✕ pressed for `id`: closed now, or — in a turn — asked about where it
    /// is shown.
    func askToClose(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        guard conversation.current.state == .working else {
            closeSession(id)
            return
        }
        confirmingClose = id
        if selected?.id != id { show(id) }
    }

    /// Ends the session's CLI and takes it off the list; a place that showed
    /// it shows another one, or none.
    func closeSession(_ id: UUID) {
        if confirmingClose == id { confirmingClose = nil }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        forget(id)
        Task {
            for agent in conversation.agents.values { await agent.close() }
            refreshHistory()
            render()
        }
    }

    /// The question asked before a session in a turn is closed.
    func closeAskRow(_ session: Conversation) -> JSONValue {
        ["id": .string("close-" + session.id.uuidString),
         "title": .string(t("Сессия работает — закрыть?", "This session is working — close it?")),
         "detail": .string(t("Ход остановится на середине. Разговор останется в истории",
                             "The turn stops where it is. The conversation stays in the history")),
         "buttons": [
             ["id": .string("closenow:" + session.id.uuidString),
              "label": .string(t("Остановить и закрыть", "Stop and close")), "primary": true],
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
