import Foundation

/// Which account a new session should run under (the operator's F5: modes,
/// Auto among them, and Auto says why).
///
/// Pure: it takes what is known about each account right now and returns a
/// pick with its reason. What the limits are and how fast they are being spent
/// is gathered elsewhere (the agents report them); the phrasing of the reason is
/// the UI's.
public enum AccountPicker {
    public enum Kind: Sendable, Equatable {
        case subscription
        /// Paid by the token: never picked unless the user allowed it.
        case apiKey
    }

    /// One limit window of an account — the 5-hour one, the week, a model's own.
    public struct Window: Sendable, Equatable {
        public let name: String
        /// 0…1.
        public let used: Double
        public let resetsAt: Date?
        /// How much of this window the account spends per hour lately, 0…1 per
        /// hour. Nil when there is no history yet: the pick is then an estimate.
        public let usePerHour: Double?
        /// The week (or the longest window): "burns soonest" is about this one.
        public let isWeekly: Bool

        public init(name: String, used: Double, resetsAt: Date?, usePerHour: Double?, isWeekly: Bool) {
            self.name = name
            self.used = used
            self.resetsAt = resetsAt
            self.usePerHour = usePerHour
            self.isWeekly = isWeekly
        }
    }

    public struct Account: Sendable, Equatable {
        public let name: String
        public let isMain: Bool
        public let kind: Kind
        public let signedIn: Bool
        public let windows: [Window]
        public let liveSessions: Int
        /// The user's own order of accounts; lower first.
        public let order: Int

        public init(name: String, isMain: Bool, kind: Kind, signedIn: Bool, windows: [Window], liveSessions: Int,
                    order: Int)
        {
            self.name = name
            self.isMain = isMain
            self.kind = kind
            self.signedIn = signedIn
            self.windows = windows
            self.liveSessions = liveSessions
            self.order = order
        }
    }

    public enum Mode: Sendable, Equatable {
        /// Most headroom left after the forecast.
        case auto
        /// Spend what would otherwise expire: the soonest weekly reset that still
        /// has something left.
        case burnFirst
        /// The main account only when nothing else can take the session.
        case spareMain
        /// Fewest sessions running, then headroom.
        case even
    }

    public enum Reason: Sendable, Equatable {
        /// The most left after what the account is expected to spend until the
        /// tightest window resets (`headroom`, 0…1).
        case mostHeadroom(headroom: Double)
        /// Its week resets soonest and still has this much left — unspent, it burns.
        case burnsSoonest(left: Double, resetsAt: Date)
        /// The fewest sessions running on it.
        case fewestSessions(Int)
        /// Every other account is out of the running; this is the main one.
        case onlyTheMainLeft
    }

    public struct Pick: Sendable, Equatable {
        public let account: String
        public let reason: Reason
        /// Some account's spending was unknown: the pick is a guess, shown as one.
        public let estimated: Bool
    }

    /// Why an account cannot take the session, for the picker to show beside it.
    public enum Exclusion: Sendable, Equatable {
        case signedOut
        case paidNotAllowed
        /// This window is spent.
        case exhausted(window: String)
        /// At the current pace this window runs out before it resets.
        case runsOut(window: String)
    }

    public static func exclusion(of account: Account, now: Date, allowPaid: Bool) -> Exclusion? {
        if !account.signedIn { return .signedOut }
        if account.kind == .apiKey && !allowPaid { return .paidNotAllowed }
        for window in account.windows {
            let left = 1 - window.used
            if left <= 0.001 { return .exhausted(window: window.name) }
            if let forecast = forecast(window, now: now), forecast > left { return .runsOut(window: window.name) }
        }
        return nil
    }

    /// What is left after the expected spending, in the tightest window.
    static func headroom(_ account: Account, now: Date) -> Double {
        account.windows.map { 1 - $0.used - (forecast($0, now: now) ?? 0) }.min() ?? 1
    }

    static func forecast(_ window: Window, now: Date) -> Double? {
        guard let perHour = window.usePerHour, let resets = window.resetsAt else { return nil }
        return perHour * max(0, resets.timeIntervalSince(now) / 3600)
    }

    static func weekly(_ account: Account) -> Window? {
        account.windows.first(where: \.isWeekly)
    }

    public static func pick(_ accounts: [Account], mode: Mode, now: Date, allowPaid: Bool = false) -> Pick? {
        let eligible = accounts.filter { exclusion(of: $0, now: now, allowPaid: allowPaid) == nil }
        guard !eligible.isEmpty else { return nil }
        let estimated = eligible.contains { account in account.windows.contains { $0.usePerHour == nil } }

        // Auto's order, also every mode's tie-break: headroom (to a hundredth),
        // then the soonest weekly reset, then fewest sessions, then the user's order.
        func autoOrder(_ a: Account, _ b: Account) -> Bool {
            let ha = (headroom(a, now: now) * 100).rounded(), hb = (headroom(b, now: now) * 100).rounded()
            if ha != hb { return ha > hb }
            let ra = weekly(a)?.resetsAt ?? .distantFuture, rb = weekly(b)?.resetsAt ?? .distantFuture
            if ra != rb { return ra < rb }
            if a.liveSessions != b.liveSessions { return a.liveSessions < b.liveSessions }
            return a.order < b.order
        }

        switch mode {
        case .auto:
            let best = eligible.sorted(by: autoOrder)[0]
            return Pick(account: best.name, reason: .mostHeadroom(headroom: headroom(best, now: now)),
                        estimated: estimated)
        case .burnFirst:
            let burning = eligible.compactMap { account -> (Account, Window, Date)? in
                guard let week = weekly(account), let resets = week.resetsAt, week.used < 1 else { return nil }
                return (account, week, resets)
            }.sorted { lhs, rhs in lhs.2 != rhs.2 ? lhs.2 < rhs.2 : autoOrder(lhs.0, rhs.0) }
            if let (account, week, resets) = burning.first {
                return Pick(account: account.name, reason: .burnsSoonest(left: 1 - week.used, resetsAt: resets),
                            estimated: estimated)
            }
            return pick(accounts, mode: .auto, now: now, allowPaid: allowPaid)
        case .spareMain:
            let others = eligible.filter { !$0.isMain }
            if let best = others.sorted(by: autoOrder).first {
                return Pick(account: best.name, reason: .mostHeadroom(headroom: headroom(best, now: now)),
                            estimated: estimated)
            }
            let main = eligible.sorted(by: autoOrder)[0]
            return Pick(account: main.name, reason: .onlyTheMainLeft, estimated: estimated)
        case .even:
            let best = eligible.sorted { a, b in
                a.liveSessions != b.liveSessions ? a.liveSessions < b.liveSessions : autoOrder(a, b)
            }[0]
            return Pick(account: best.name, reason: .fewestSessions(best.liveSessions), estimated: estimated)
        }
    }
}
