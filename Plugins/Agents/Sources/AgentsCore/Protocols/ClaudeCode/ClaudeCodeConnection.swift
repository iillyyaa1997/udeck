import Foundation
import UDeckAgents

/// One Claude Code session: the user's `claude` running in stream-json mode,
/// and the control protocol on top of its lines.
///
/// Everything the CLI writes comes out of `events`, in order — except the
/// answers to requests uDeck itself sent, which go to whoever is awaiting them
/// in `request(_:timeout:)`. The CLI's own requests (permission asks, questions)
/// come out of `events` as `.request`; the caller answers them with `send`.
public actor ClaudeCodeConnection {
    public enum Failure: Error, Equatable {
        case timedOut(String)
        case closed
        case refused(String)
    }

    public nonisolated let events: AsyncStream<ClaudeInbound>
    private let eventsContinuation: AsyncStream<ClaudeInbound>.Continuation
    private let process: any AgentChannel
    private let nextID: @Sendable () -> String
    private var pending: [String: CheckedContinuation<ClaudeControlResponse, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var finished = false

    /// - Parameters:
    ///   - executable: the user's own `claude`, resolved through their shell's PATH.
    ///   - environment: exactly what the agent should see (the user's shell
    ///     environment, plus `CLAUDE_CONFIG_DIR` for an extra account).
    ///   - nextID: request ids; tests pass the ids of a recording.
    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                nextID: @escaping @Sendable () -> String = { "udeck-" + UUID().uuidString.prefix(8).lowercased() })
        throws
    {
        self.init(channel: try AgentProcess(executable: executable, arguments: arguments,
                                            environment: environment, directory: directory),
                  nextID: nextID)
    }

    /// Over an agent someone else started — the helper, which keeps it running
    /// while uDeck restarts.
    public init(channel: any AgentChannel,
                nextID: @escaping @Sendable () -> String = { "udeck-" + UUID().uuidString.prefix(8).lowercased() })
    {
        process = channel
        self.nextID = nextID
        (events, eventsContinuation) = AsyncStream.makeStream(of: ClaudeInbound.self)
    }

    /// Starts reading. Call once, right after creating the connection.
    public func start() {
        guard reader == nil else { return }
        let lines = process.lines
        reader = Task { [weak self] in
            for await piece in lines {
                guard let self else { return }
                await self.receive(piece)
            }
            await self?.streamEnded()
        }
    }

    private func receive(_ piece: LineFramer.Piece) {
        guard case .line(let text) = piece, let message = ClaudeInbound(line: Substring(text)) else {
            // Not JSON (a stray print) or an over-long line: nothing to route
            // yet. The chat will show these as a diagnostic note in the feed.
            return
        }
        if case .response(let response) = message, let waiter = pending.removeValue(forKey: response.requestID) {
            if response.succeeded {
                waiter.resume(returning: response)
            } else {
                waiter.resume(throwing: Failure.refused(response.error ?? "refused"))
            }
            return
        }
        eventsContinuation.yield(message)
    }

    private func streamEnded() {
        finished = true
        for waiter in pending.values { waiter.resume(throwing: Failure.closed) }
        pending.removeAll()
        eventsContinuation.finish()
    }

    /// Writes one message: a user message, or an answer to one of the CLI's
    /// requests.
    public func send(_ message: JSONValue) throws {
        guard !finished else { throw Failure.closed }
        try process.write(line: message.encodedLine())
    }

    /// Sends a control request built with a fresh id and waits for its answer.
    public func request(_ build: @Sendable (String) -> JSONValue, timeout: Duration = .seconds(30)) async throws
        -> ClaudeControlResponse
    {
        guard !finished else { throw Failure.closed }
        let id = nextID()
        let message = build(id)
        return try await withThrowingTaskGroup(of: ClaudeControlResponse.self) { group in
            group.addTask { try await self.awaitResponse(id: id, sending: message) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut(id)
            }
            defer { group.cancelAll() }
            do {
                let first = try await group.next()!
                return first
            } catch {
                await self.forget(id)
                throw error
            }
        }
    }

    private func awaitResponse(id: String, sending message: JSONValue) async throws -> ClaudeControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try process.write(line: message.encodedLine())
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: Failure.closed)
            }
        }
    }

    private func forget(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(id))
    }

    /// Ends the session the way the SDK does: close stdin, let the CLI finish,
    /// and terminate it if it does not exit within `grace`.
    public func close(grace: Duration = .seconds(5)) async -> AgentProcess.Exit {
        process.closeInput()
        // Within `grace` for real: a task group would have waited for the
        // exit anyway (`AgentChannel.exit(within:)`).
        if let exit = await process.exit(within: grace) { return exit }
        return await process.terminate(grace: .seconds(3))
    }

    public nonisolated var processIdentifier: Int32 { process.processIdentifier }
}
