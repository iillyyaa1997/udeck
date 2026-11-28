import Foundation
import UDeckAgents

/// What the context's details do (the operator's builder, 11-28): compact
/// now, compact with a hint of what to keep, a new chat with a summary — and
/// a compaction in the pause after a turn, before the CLI does it by itself in
/// the middle of one (104 s of «Отправляет запрос» on 11-27).
extension AgentsApp {
    func pressContext(_ id: String) {
        guard let conversation = selected else { return }
        switch id {
        case "ctx:compact":
            Task {
                if await !commandFromTheField("/compact") { conversation.send("/compact") }
                render()
            }
        case "ctx:hint":
            // What to keep is the person's to write: the command in the field.
            conversation.fill = ("hint-" + UUID().uuidString,
                                 t("/compact сохрани: решения, открытые вопросы, файлы и текущую задачу",
                                   "/compact keep: decisions, open questions, files and the task at hand"))
        case "ctx:fresh":
            let summary = conversation.claude?.contextTrack.compactions.last?.summary ?? conversation.recap
            let provider = conversation.active
            let title = conversation.title
            Task {
                await newConversation(in: conversation.folder, provider: provider)
                guard let fresh = selected, fresh.id != conversation.id else { return }
                fresh.carry(t("Это продолжение разговора «\(title)». Что было в нём:\n\n",
                              "This goes on from the conversation «\(title)». What happened in it:\n\n") + summary)
                fresh.current.note("carried:\(summary.count / 4)")
                render()
            }
        default:
            break
        }
    }

    /// After a turn: compacted now, in the pause, when the context is past
    /// the share the person chose — not again within five minutes of the last
    /// compaction, whose result also ends a turn.
    func compactInThePause(_ conversation: Conversation) {
        guard conversation.active == .claude, let session = conversation.claude,
              let window = session.context?.window, let tokens = session.contextTokens,
              let percent = Self.compactsInThePause(look: settings.context, idle: session.state == .idle,
                                                    waiting: session.waitingMessages.count + session.unsentMessages.count,
                                                    tokens: tokens, window: window,
                                                    lastCompaction: session.contextTrack.compactions.last?.at)
        else { return }
        session.note("pause-compact:\(percent)")
        conversation.send("/compact")
    }

    /// Whether to compact now, and at what fill: on, idle, nothing waiting,
    /// past the share chosen, and the last compaction over five minutes ago.
    nonisolated static func compactsInThePause(look: ContextLook, idle: Bool, waiting: Int, tokens: Int, window: Int,
                                               lastCompaction: Date?, now: Date = Date()) -> Int? {
        guard look.pause, idle, waiting == 0, window > 0 else { return nil }
        let percent = Int((Double(tokens) / Double(window) * 100).rounded())
        guard percent >= look.pauseAt else { return nil }
        if let lastCompaction, now.timeIntervalSince(lastCompaction) < 300 { return nil }
        return percent
    }
}
