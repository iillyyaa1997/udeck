import Foundation

/// What uDeck knows about a host's limit, kept in `state.json` so that a
/// relaunch does not start by spending what is left.
///
/// Without signing in GitHub allows 60 API requests an hour per network
/// address — not per application: everything behind the same connection shares
/// them, and a `304` costs one too. So uDeck reads what is left from every
/// answer, keeps a reserve for what the operator presses, and stops asking
/// altogether once the host says the limit is used up. Raw file requests are
/// counted separately and their limits are not published, so a `429` from the
/// raw host stops raw requests for an hour and nothing cleverer.
///
/// GitLab says the same without the `x-` (`ratelimit-remaining`,
/// `ratelimit-reset`, **measured**: `ratelimit-reset: 1792276920`), and
/// gitlab.com counts by more than one limiter, naming the one each answer was
/// counted by (`ratelimit-name`): `throttle_unauthenticated_api`, which resets
/// each minute, and `unauthenticated_traffic_per_ip`, which resets on the hour
/// (S4-16). Each limiter's pair is kept apart (`limiters`), and what a read
/// nobody asked for goes by is the one with the least left that has not reset —
/// with one pair, a minute's hundreds left would hide an hour's few. A
/// self-hosted GitLab sends no limit at all (**measured** on 18.8.2): there only
/// a `429` and its `Retry-After` count.
public struct RateLimitState: Codable, Equatable, Sendable {
    /// `x-ratelimit-remaining` from the last API answer that carried it.
    public var remaining: Int?
    /// `x-ratelimit-reset` from the same answer.
    public var reset: Date?
    /// No API request goes to the host before this.
    public var blockedUntil: Date?
    /// No raw file request goes to the raw host before this.
    public var rawBlockedUntil: Date?
    /// GitLab's limiters, by the name each answer gave (`ratelimit-name`):
    /// what each said was left, and when it resets. Nil for a host that names
    /// none — GitHub's — and absent from the file then; an older uDeck reads
    /// a state with it as one without.
    public var limiters: [String: Limiter]?

    /// One limiter's count, as its last answer said it.
    public struct Limiter: Codable, Equatable, Sendable {
        public var remaining: Int
        public var reset: Date?

        public init(remaining: Int, reset: Date?) {
            self.remaining = remaining
            self.reset = reset
        }
    }

    /// A refresh nobody asked for does not start while fewer than this many
    /// requests are left before the reset. The rest is kept for what the
    /// operator presses, and for whatever else shares the connection.
    public static let reserveForTheOperator = 10

    /// How long the raw host is left alone after it answers `429`.
    public static let rawPause: TimeInterval = 3600

    public init(remaining: Int? = nil, reset: Date? = nil, blockedUntil: Date? = nil, rawBlockedUntil: Date? = nil,
                limiters: [String: Limiter]? = nil) {
        self.remaining = remaining
        self.reset = reset
        self.blockedUntil = blockedUntil
        self.rawBlockedUntil = rawBlockedUntil
        self.limiters = limiters
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
    /// blocked, and not while the reserve is all that is left before the reset
    /// — of the limiter with the least left that has not reset, where the
    /// host counts by more than one.
    public func allowsUnrequested(now: Date) -> Bool {
        if apiBlocked(now: now) != nil { return false }
        if let left = leastLeft(now: now) { return left >= Self.reserveForTheOperator }
        guard let remaining else { return true }
        if let reset, reset <= now { return true }
        return remaining >= Self.reserveForTheOperator
    }

    /// What is left of the limiter with the least left that has not reset —
    /// nil when no limiter is named, or every one named has reset.
    public func leastLeft(now: Date) -> Int? {
        (limiters ?? [:]).values.filter { limiter in limiter.reset.map { $0 > now } ?? true }.map(\.remaining).min()
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
    ///
    /// Without `x-ratelimit-remaining` and `x-ratelimit-reset`, GitLab's
    /// `ratelimit-remaining` and `ratelimit-reset` are read the same way, in
    /// Unix seconds; with `ratelimit-name`, as that limiter's.
    public mutating func observeAPI(status: Int, headers: [String: String], now: Date) -> Verdict {
        func number(_ name: String) -> Int? { header(name, in: headers).flatMap { Int($0) } }
        func date(_ name: String) -> Date? {
            header(name, in: headers).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        }
        var remainingHeader = number("x-ratelimit-remaining")
        var resetHeader = date("x-ratelimit-reset")
        let gitLab = remainingHeader == nil && resetHeader == nil
        if gitLab {
            remainingHeader = number("ratelimit-remaining")
            resetHeader = date("ratelimit-reset")
        }
        let retryAfter = header("retry-after", in: headers).flatMap(TimeInterval.init)

        if gitLab, let name = header("ratelimit-name", in: headers), !name.isEmpty, let remainingHeader {
            var named = limiters ?? [:]
            named[name] = Limiter(remaining: remainingHeader, reset: resetHeader)
            limiters = named
        } else {
            if let remainingHeader { remaining = remainingHeader }
            if let resetHeader { reset = resetHeader }
        }

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
