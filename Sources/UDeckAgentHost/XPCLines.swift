import Foundation

/// The one message the two sides exchange: a line of the helper's protocol.
@objc(UDeckLineCarrier)
protocol LineCarrier {
    func line(_ data: Data)
}

private final class LineReceiver: NSObject, LineCarrier, @unchecked Sendable {
    let continuation: AsyncStream<String>.Continuation

    init(_ continuation: AsyncStream<String>.Continuation) { self.continuation = continuation }

    func line(_ data: Data) { continuation.yield(String(decoding: data, as: UTF8.self)) }
}

/// An XPC connection carrying the helper's protocol lines both ways, with the
/// other side's code-signing requirement checked on every message it sends.
///
/// XPC delivers one connection's messages in the order they were sent, so the
/// protocol's ordering rules hold as they would on a pipe. The connection ends
/// for good on invalidation and on interruption alike: the other side's state
/// (hello, subscriptions) is gone either way, and the protocol starts over.
final class XPCLines: @unchecked Sendable {
    let lines: AsyncStream<String>
    private let connection: NSXPCConnection
    private let closed = Guarded(false)

    init(_ connection: NSXPCConnection, requirement: String?) {
        self.connection = connection
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        let interface = NSXPCInterface(with: LineCarrier.self)
        connection.exportedInterface = interface
        connection.remoteObjectInterface = interface
        connection.exportedObject = LineReceiver(continuation)
        let closed = self.closed
        connection.invalidationHandler = {
            closed.withLock { $0 = true }
            continuation.finish()
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        connection.resume()
    }

    /// Sends one line. False once the connection is closed.
    @discardableResult
    func send(_ line: String) -> Bool {
        guard !isClosed else { return false }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.close() }
        guard let carrier = proxy as? LineCarrier else { return false }
        carrier.line(Data(line.utf8))
        return true
    }

    var isClosed: Bool { closed.withLock { $0 } }

    var processIdentifier: pid_t { connection.processIdentifier }

    /// Runs `body` once every message sent so far has gone.
    func afterPendingSends(_ body: @escaping @Sendable () -> Void) {
        connection.scheduleSendBarrierBlock(body)
    }

    func close() {
        connection.invalidate()
    }
}
