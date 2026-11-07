import Foundation

/// The tokens handed out for the reads and presses of the sources of one's
/// own, and whose turn it is to change one (S4-17 to S4-20). Pure, so it is
/// tested; the application keeps one and asks it.
///
/// * Every change of a source's token — a token checked under **Token…** or
///   the token step, **Forget the token**, **Remove…** — begins with a
///   ticket, and a later one takes the turn from every earlier one: a check
///   that comes back after Forget or Remove was pressed, or after another
///   token was pasted, changes nothing (`isCurrent`). A lookup that only
///   reads the vault holds the ticket as it stood (`ticket`).
/// * A token is handed out under a lease (`CredentialLease`) that every client
///   holding a copy asks before each request: withdrawn — forgotten, replaced,
///   its source removed, gone from `sources.json`, switched to no token, or
///   now another repository's number — or refused by the host, no client
///   sends it again.
public struct SourceTokenBook: Sendable {
    /// A turn to change one source's token.
    public struct Ticket: Equatable, Sendable {
        public let source: String
        let turn: Int
    }

    private var turns: [String: Int] = [:]
    private var held: [String: SourceCredential] = [:]

    public init() {}

    /// A ticket for a change of `source`'s token: every ticket before it
    /// loses its turn.
    public mutating func begin(_ source: String) -> Ticket {
        turns[source, default: 0] += 1
        return Ticket(source: source, turn: turns[source, default: 0])
    }

    /// The turn as it stands, for a lookup that keeps what it found only if
    /// nothing changed the token meanwhile.
    public func ticket(_ source: String) -> Ticket {
        Ticket(source: source, turn: turns[source, default: 0])
    }

    /// Whether nothing began after `ticket`.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        turns[ticket.source, default: 0] == ticket.turn
    }

    /// `credential` handed out for the ticket's source, under its lease — nil,
    /// and nothing changed, when the ticket lost its turn, or when the host
    /// refused the token held and this is no press that may send one again
    /// (`renewingRejected`: Check now, Token…, Add) — a lookup that waited on
    /// the Keychain while another reader heard the `401` never hands the
    /// refused token out again. The same token already held under a lease
    /// that holds stays as it is, every client's copy with it; another token,
    /// or one whose lease ended, gets a new lease, and the one before ends.
    public mutating func hold(_ credential: SourceCredential, for ticket: Ticket,
                              renewingRejected: Bool = false) -> SourceCredential? {
        guard isCurrent(ticket) else { return nil }
        if !renewingRejected, wasRejected(ticket.source) { return nil }
        if let current = held[ticket.source], current == credential, current.lease?.ending == nil { return current }
        held[ticket.source]?.lease?.end(.withdrawn)
        var leased = credential
        leased.lease = CredentialLease()
        held[ticket.source] = leased
        return leased
    }

    /// `source`'s token taken back: its lease ends, nothing is held, and every
    /// ticket before loses its turn.
    public mutating func withdraw(_ source: String) {
        _ = begin(source)
        held[source]?.lease?.end(.withdrawn)
        held[source] = nil
    }

    /// `source`'s token no longer held — the vault said none, or another
    /// origin's, or could not be read — its lease ended, with no change of
    /// turn: a check under way for a new token keeps its turn.
    /// A token the host refused stays held as refused: a lookup that failed
    /// at the Keychain does not make it sendable again.
    public mutating func release(_ source: String) {
        guard !wasRejected(source) else { return }
        held[source]?.lease?.end(.withdrawn)
        held[source] = nil
    }

    /// What `source`'s requests carry now: its token while its lease holds.
    public func credential(of source: String) -> SourceCredential? {
        guard let current = held[source], current.lease?.ending == nil else { return nil }
        return current
    }

    /// Whether the host refused the token `source` holds (`401`): nothing is
    /// sent until Check now or Token… hands out a token again.
    public func wasRejected(_ source: String) -> Bool {
        held[source]?.lease?.ending == .rejected
    }

    /// Every token held for a source no longer read with it — gone from
    /// `sources.json`, its `access` none, or its provider or number another
    /// than the token was checked with — withdrawn; their ids, in order.
    public mutating func reconcile(with sources: [OwnSource]) -> [String] {
        var withdrawn: [String] = []
        for id in held.keys.sorted() {
            let source = sources.first { $0.id == id }
            guard let source, source.access != OwnSource.Access.none,
                  let binding = held[id]?.binding,
                  binding.provider == source.provider, binding.remoteID == source.remoteID else {
                withdraw(id)
                withdrawn.append(id)
                continue
            }
        }
        return withdrawn
    }
}
