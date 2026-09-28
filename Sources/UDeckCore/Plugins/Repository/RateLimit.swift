import Foundation

/// What uDeck knows about GitHub's hourly limit, kept in `state.json` so that a
/// relaunch does not start by spending what is left.
///
/// Without signing in GitHub allows 60 API requests an hour per network
/// address — not per application: everything behind the same connection shares
/// them, and a `304` costs one too. So uDeck reads what is left from every
/// answer, keeps a reserve for what the operator presses, and stops asking
/// altogether once the host says the limit is used up. Raw file requests are
/// counted separately and their limits are not published, so a `429` from the
/// raw host stops raw requests for an hour and nothing cleverer.
public struct RateLimitState: Codable, Equatable, Sendable {
    /// `x-ratelimit-remaining` from the last API answer that carried it.
    public var remaining: Int?
    /// `x-ratelimit-reset` from the same answer.
    public var reset: Date?
    /// No API request goes to the host before this.
    public var blockedUntil: Date?
    /// No raw file request goes to the raw host before this.
    public var rawBlockedUntil: Date?

    /// A refresh nobody asked for does not start while fewer than this many
    /// requests are left before the reset. The rest is kept for what the
    /// operator presses, and for whatever else shares the connection.
    public static let reserveForTheOperator = 10

    /// How long the raw host is left alone after it answers `429`.
    public static let rawPause: TimeInterval = 3600

    public init(remaining: Int? = nil, reset: Date? = nil, blockedUntil: Date? = nil, rawBlockedUntil: Date? = nil) {
        self.remaining = remaining
        self.reset = reset
        self.blockedUntil = blockedUntil
        self.rawBlockedUntil = rawBlockedUntil
    }

    /// Whether an API request may be sent now, and if not, until when not.
    public func apiBlocked(now: Date) -> Date? {
        guard let blockedUntil, blockedUntil > now else { return nil }
        return blockedUntil
    }

    public func rawBlocked(now: Date) -> Date? {
        guard let rawBlockedUntil, rawBlockedUntil > now else { return nil }
        return rawBlockedUntil
    }

    /// Whether a refresh nobody asked for may start: never while the host is
    /// blocked, and not while the reserve is all that is left before the reset.
    public func allowsUnrequested(now: Date) -> Bool {
        if apiBlocked(now: now) != nil { return false }
        guard let remaining else { return true }
        if let reset, reset <= now { return true }
        return remaining >= Self.reserveForTheOperator
    }

    /// What an API answer says about the limit.
    public enum Verdict: Equatable, Sendable {
        /// An ordinary answer.
        case fine
        /// The limit is used up, or the host asked for a pause; nothing more
        /// until the date.
        case limited(until: Date)
        /// A `403` that is not a limit: a refusal, reported as the refusal it is.
        case refused
    }

    /// Takes in one API answer: its status and headers.
    ///
    /// * `403` or `429` with `x-ratelimit-remaining: 0` — no API request until
    ///   `x-ratelimit-reset`.
    /// * `403` or `429` with `Retry-After` — the same, for that many seconds.
    /// * A `403` with neither is not a limit.
    public mutating func observeAPI(status: Int, headers: [String: String], now: Date) -> Verdict {
        let remainingHeader = header("x-ratelimit-remaining", in: headers).flatMap { Int($0) }
        let resetHeader = header("x-ratelimit-reset", in: headers)
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        let retryAfter = header("retry-after", in: headers).flatMap(TimeInterval.init)

        if let remainingHeader { remaining = remainingHeader }
        if let resetHeader { reset = resetHeader }

        guard status == 403 || status == 429 else { return .fine }
        if let retryAfter, retryAfter >= 0 {
            let until = now.addingTimeInterval(retryAfter)
            blockedUntil = max(blockedUntil ?? until, until)
            return .limited(until: blockedUntil!)
        }
        if remainingHeader == 0 {
            // A reset in the past or missing would unblock at once and start
            // the same refusal again; an hour is what GitHub's window is.
            let until = (resetHeader.map { $0 > now ? $0 : nil } ?? nil) ?? now.addingTimeInterval(3600)
            blockedUntil = until
            return .limited(until: until)
        }
        guard status == 429 else { return .refused }
        // "Too many requests" with nothing to say how long for: the document
        // names no schedule, so a minute — long enough not to hammer a host
        // that just asked for quiet, short enough not to strand the operator.
        let until = now.addingTimeInterval(60)
        blockedUntil = until
        return .limited(until: until)
    }

    /// Takes in one raw file answer. Only a `429` means anything here.
    public mutating func observeRaw(status: Int, now: Date) -> Date? {
        guard status == 429 else { return nil }
        let until = now.addingTimeInterval(Self.rawPause)
        rawBlockedUntil = until
        return until
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value.trimmingCharacters(in: .whitespaces)
    }
}
