import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// The picture the operator approved on 2026-11-21: four accounts, Auto picks
/// work because its week resets in nine hours with 88 % left.
@Suite("Which account a new session runs under")
struct AccountPickerTests {
    static let now = Date(timeIntervalSince1970: 1_795_226_400) // a Saturday, 00:40 in Belgrade
    static func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

    static func week(_ used: Double, resetsIn hours: Double, perDay: Double?) -> AccountPicker.Window {
        AccountPicker.Window(name: "week", used: used, resetsAt: Self.hours(hours),
                             usePerHour: perDay.map { $0 / 24 }, isWeekly: true)
    }

    static func account(_ name: String, main: Bool = false, kind: AccountPicker.Kind = .subscription,
                        _ windows: [AccountPicker.Window], sessions: Int = 0, order: Int) -> AccountPicker.Account {
        AccountPicker.Account(name: name, isMain: main, kind: kind, signedIn: true, windows: windows,
                              liveSessions: sessions, order: order)
    }

    /// pers: 30 % of the week, spending 41 % a day, resets in six days — it runs out first.
    /// pers2: spent. work: 12 %, little spent, resets in nine hours. api: paid.
    static let operatorsAccounts = [
        account("pers", main: true, [week(0.30, resetsIn: 146, perDay: 0.41)], sessions: 3, order: 0),
        account("pers2", [week(1.00, resetsIn: 45, perDay: 0.10)], order: 1),
        account("work", [week(0.12, resetsIn: 9, perDay: 0.05)], order: 2),
        account("api", kind: .apiKey, [], order: 3),
    ]

    @Test("Auto picks work, the account with the most headroom after its forecast")
    func auto() throws {
        let pick = try #require(AccountPicker.pick(Self.operatorsAccounts, mode: .auto, now: Self.now))
        #expect(pick.account == "work")
        guard case .mostHeadroom(let headroom) = pick.reason else { Issue.record("\(pick.reason)"); return }
        #expect(headroom > 0.8 && headroom < 0.9)
        #expect(!pick.estimated)
    }

    @Test("each excluded account says why: pers runs out before its reset, pers2 is spent, api is paid")
    func exclusions() {
        let reasons = Dictionary(uniqueKeysWithValues: Self.operatorsAccounts.map {
            ($0.name, AccountPicker.exclusion(of: $0, now: Self.now, allowPaid: false))
        })
        #expect(reasons["pers"] == .some(.runsOut(window: "week")))
        #expect(reasons["pers2"] == .some(.exhausted(window: "week")))
        #expect(reasons["api"] == .some(.paidNotAllowed))
        #expect(reasons["work"] == .some(nil))
    }

    @Test("burn first takes the soonest weekly reset that still has something left")
    func burnFirst() throws {
        let accounts = [
            Self.account("a", [Self.week(0.20, resetsIn: 100, perDay: 0.05)], order: 0),
            Self.account("b", [Self.week(0.60, resetsIn: 20, perDay: 0.05)], order: 1),
        ]
        let pick = try #require(AccountPicker.pick(accounts, mode: .burnFirst, now: Self.now))
        #expect(pick.account == "b")
        #expect(pick.reason == .burnsSoonest(left: 0.4, resetsAt: Self.hours(20)))
        // Auto would take a: more headroom.
        #expect(AccountPicker.pick(accounts, mode: .auto, now: Self.now)?.account == "a")
    }

    @Test("spare the main uses another account while one can take the session, the main only when none can")
    func spareMain() throws {
        let main = Self.account("main", main: true, [Self.week(0.10, resetsIn: 100, perDay: 0.01)], order: 0)
        let other = Self.account("other", [Self.week(0.70, resetsIn: 100, perDay: 0.001)], order: 1)
        #expect(AccountPicker.pick([main, other], mode: .spareMain, now: Self.now)?.account == "other")
        let spent = Self.account("other", [Self.week(1.0, resetsIn: 100, perDay: 0.001)], order: 1)
        let pick = try #require(AccountPicker.pick([main, spent], mode: .spareMain, now: Self.now))
        #expect(pick.account == "main")
        #expect(pick.reason == .onlyTheMainLeft)
    }

    @Test("even takes the account with the fewest sessions running")
    func even() throws {
        let busy = Self.account("busy", [Self.week(0.10, resetsIn: 100, perDay: 0.01)], sessions: 4, order: 0)
        let quiet = Self.account("quiet", [Self.week(0.50, resetsIn: 100, perDay: 0.01)], sessions: 1, order: 1)
        let pick = try #require(AccountPicker.pick([busy, quiet], mode: .even, now: Self.now))
        #expect(pick.account == "quiet")
        #expect(pick.reason == .fewestSessions(1))
    }

    @Test("an account with no spending history yet is eligible, and the pick says it is an estimate")
    func estimate() throws {
        let fresh = Self.account("fresh", [Self.week(0.05, resetsIn: 100, perDay: nil)], order: 0)
        let pick = try #require(AccountPicker.pick([fresh], mode: .auto, now: Self.now))
        #expect(pick.account == "fresh")
        #expect(pick.estimated)
    }

    @Test("the tightest window decides: a full 5-hour window takes an account out even with the week fine")
    func tightestWindow() {
        let fiveHour = AccountPicker.Window(name: "five_hour", used: 1.0, resetsAt: Self.hours(2), usePerHour: nil,
                                            isWeekly: false)
        let account = Self.account("a", [fiveHour, Self.week(0.1, resetsIn: 100, perDay: 0.01)], order: 0)
        #expect(AccountPicker.exclusion(of: account, now: Self.now, allowPaid: false) == .exhausted(window: "five_hour"))
        #expect(AccountPicker.pick([account], mode: .auto, now: Self.now) == nil)
    }

    @Test("a paid account is picked only when the user allowed it, and a signed-out one never")
    func paidAndSignedOut() {
        let paid = Self.account("api", kind: .apiKey, [], order: 0)
        #expect(AccountPicker.pick([paid], mode: .auto, now: Self.now) == nil)
        #expect(AccountPicker.pick([paid], mode: .auto, now: Self.now, allowPaid: true)?.account == "api")
        let out = AccountPicker.Account(name: "out", isMain: false, kind: .subscription, signedIn: false,
                                        windows: [], liveSessions: 0, order: 0)
        #expect(AccountPicker.exclusion(of: out, now: Self.now, allowPaid: true) == .signedOut)
    }
}
