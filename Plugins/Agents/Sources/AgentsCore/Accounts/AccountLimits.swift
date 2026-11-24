import Foundation

/// What an account's limits were last seen to be: the 5-hour window and the
/// week, as the CLI reports them during a turn (`rate_limit_event`) and after
/// it (`get_usage`), and a limit it refused at, until it resets.
public struct AccountLimits: Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var week: UsageWindow?
    /// The account stopped a turn at its limit; until then nothing more runs on it.
    public var limitedUntil: Date?
    public var seenAt: Date

    public init(fiveHour: UsageWindow? = nil, week: UsageWindow? = nil, limitedUntil: Date? = nil, seenAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.week = week
        self.limitedUntil = limitedUntil
        self.seenAt = seenAt
    }

    /// Whether the account is at its limit now.
    public func isLimited(at now: Date) -> Bool {
        guard let limitedUntil else { return false }
        return limitedUntil > now
    }

    /// The whole picture after a turn: what it says replaces what was known,
    /// and a limit it no longer shows is over.
    mutating func note(_ usage: ClaudeUsage, at now: Date) {
        if let window = usage.fiveHour { fiveHour = window }
        if let window = usage.sevenDay { week = window }
        seenAt = now
        if let limitedUntil, limitedUntil <= now { self.limitedUntil = nil }
        if [fiveHour, week].compactMap({ $0 }).allSatisfy({ $0.used < 0.999 }), usage.fiveHour != nil || usage.sevenDay != nil {
            limitedUntil = nil
        }
    }

    /// One window as the CLI reported it during a turn — `five_hour`,
    /// `seven_day` or a model's own week — and a refusal at it.
    mutating func note(_ limit: ClaudeRateLimit, at now: Date) {
        if limit.window == "five_hour" {
            fiveHour = limit.usage
        } else if limit.window.hasPrefix("seven_day") {
            // A model's own week counts when it is the fuller one.
            if week == nil || limit.usage.used >= (week?.used ?? 0) { week = limit.usage }
        }
        seenAt = now
        if limit.status == "rejected" {
            limitedUntil = limit.usage.resetsAt ?? now.addingTimeInterval(3600)
        }
    }

    /// The windows as the picker weighs them, a limit refused at as a window
    /// spent until it resets.
    func windows(now: Date) -> [AccountPicker.Window] {
        var windows: [AccountPicker.Window] = []
        if let fiveHour {
            windows.append(.init(name: "5h", used: fiveHour.used, resetsAt: fiveHour.resetsAt, usePerHour: nil, isWeekly: false))
        }
        if let week {
            windows.append(.init(name: "week", used: week.used, resetsAt: week.resetsAt, usePerHour: nil, isWeekly: true))
        }
        if isLimited(at: now) {
            windows.append(.init(name: "limit", used: 1, resetsAt: limitedUntil, usePerHour: nil, isWeekly: false))
        }
        return windows
    }
}

/// How «Авто» picks an account, as the plugin's setting says
/// (`UDECK_SETTING_ACCOUNT_MODE`): what would expire first unless told otherwise.
public enum AccountMode: String, CaseIterable, Sendable {
    case burnFirst, headroom, spareMain, even

    var picker: AccountPicker.Mode {
        switch self {
        case .burnFirst: .burnFirst
        case .headroom: .auto
        case .spareMain: .spareMain
        case .even: .even
        }
    }

    static func fromSetting(_ raw: String?) -> AccountMode {
        raw.flatMap(AccountMode.init(rawValue:)) ?? .burnFirst
    }
}
