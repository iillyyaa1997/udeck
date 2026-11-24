import Foundation
import UDeckAgents

/// One `codex app-server`: JSON-RPC over the program's stdio.
///
/// One server hosts many threads (sessions) of one account. Notifications and
/// the server's own requests (approvals) come out of `events`, in order; the
/// answers to uDeck's requests go to whoever awaits them in `request`.
public actor CodexConnection {
    public enum Failure: Error, Equatable {
        case timedOut(Int)
        case closed
        case refused(code: Int, message: String)
    }

    public nonisolated let events: AsyncStream<CodexInbound>
    private let eventsContinuation: AsyncStream<CodexInbound>.Continuation
    private let process: any AgentChannel
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var finished = false

    public init(executable: URL, arguments: [String] = ["app-server"], environment: [String: String],
                directory: URL) throws
    {
        self.init(channel: try AgentProcess(executable: executable, arguments: arguments,
                                            environment: environment, directory: directory))
    }

    /// Over an agent someone else started — the helper, which keeps it running
    /// while uDeck restarts.
    public init(channel: any AgentChannel) {
        process = channel
        (events, eventsContinuation) = AsyncStream.makeStream(of: CodexInbound.self)
    }

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
        guard case .line(let text) = piece, let message = CodexInbound(line: Substring(text)) else { return }
        switch message {
        case .response(let id, let result):
            if let key = id.int, let waiter = pending.removeValue(forKey: key) {
                waiter.resume(returning: result)
                return
            }
        case .failure(let id, let code, let text):
            if let key = id.int, let waiter = pending.removeValue(forKey: key) {
                waiter.resume(throwing: Failure.refused(code: code, message: text))
                return
            }
        default:
            break
        }
        eventsContinuation.yield(message)
    }

    private func streamEnded() {
        finished = true
        for waiter in pending.values { waiter.resume(throwing: Failure.closed) }
        pending.removeAll()
        eventsContinuation.finish()
    }

    /// Writes one message: a notification, or the answer to a server request.
    public func send(_ message: JSONValue) throws {
        guard !finished else { throw Failure.closed }
        try process.write(line: message.encodedLine())
    }

    /// Sends a request with the next id and waits for its result.
    public func request(_ method: String, _ params: JSONValue = .object([:]), timeout: Duration = .seconds(60))
        async throws -> JSONValue
    {
        guard !finished else { throw Failure.closed }
        nextID += 1
        let id = nextID
        let message = CodexOutbound.request(id: id, method, params)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.awaitResult(id: id, sending: message) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut(id)
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                await self.forget(id)
                throw error
            }
        }
    }

    /// `initialize`, then the `initialized` notification the server expects.
    public func handshake(client: String, version: String) async throws -> JSONValue {
        let result = try await request("initialize", ["clientInfo": ["name": .string(client), "version": .string(version)]])
        try send(CodexOutbound.initialized)
        return result
    }

    private func awaitResult(id: Int, sending message: JSONValue) async throws -> JSONValue {
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

    private func forget(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(id))
    }

    public func close(grace: Duration = .seconds(5)) async -> AgentProcess.Exit {
        process.closeInput()
        let exit = await withTaskGroup(of: AgentProcess.Exit?.self) { group in
            group.addTask { await self.process.exit() }
            group.addTask {
                try? await Task.sleep(for: grace)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        if let exit { return exit }
        return await process.terminate(grace: .seconds(3))
    }
}
