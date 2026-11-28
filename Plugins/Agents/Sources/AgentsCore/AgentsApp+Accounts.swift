import Foundation
import UDeckAgents

/// The accounts a Claude session runs on: what their limits are, which one
/// «Авто» picks, and a session going on elsewhere — or later — when its
/// account ran out (spec §10.7, §10.18; the operator's «4»: automatic, no
/// clicks).
extension AgentsApp {
    /// How «Авто» picks: the plugin's setting.
    var accountMode: AccountMode {
        AccountMode.fromSetting(settings.values["account_mode"]?.string)
    }

    /// The accounts as the picker weighs them, now.
    func pickerAccounts(now: Date = Date()) -> [AccountPicker.Account] {
        accounts.enumerated().map { index, account in
            let live = conversations.filter { conversation in
                guard let claude = conversation.claude else { return false }
                return claude.account == account && !claude.isEnded
            }.count
            return AccountPicker.Account(name: account.name, isMain: account.configDir == nil, kind: .subscription,
                                         signedIn: true, windows: limits[account.name]?.windows(now: now) ?? [],
                                         liveSessions: live, order: index)
        }
    }

    /// The account «Авто» would pick now, and why — leaving out `excluded`
    /// and, for a session going on elsewhere, any account its sessions are
    /// not shared with.
    func autoPick(excluding excluded: Set<String> = [], sharingWith source: ChatAccount? = nil,
                  now: Date = Date()) -> (account: ChatAccount, pick: AccountPicker.Pick)? {
        let candidates = pickerAccounts(now: now).filter { candidate in
            guard !excluded.contains(candidate.name) else { return false }
            guard let source, let account = accounts.first(where: { $0.name == candidate.name }) else { return true }
            return sharesSessions(source, account)
        }
        guard let pick = AccountPicker.pick(candidates, mode: accountMode.picker, now: now),
              let account = accounts.first(where: { $0.name == pick.account }) else { return nil }
        return (account, pick)
    }

    /// The account a session from the history goes on under. The history is
    /// read from the main account's transcripts: with «Авто», the account it
    /// would pick among those that share them — 11-26 a session continued
    /// from the history went on under the main account, a week's limit spent,
    /// and waited for its reset; by hand, the one chosen.
    func historyAccount(for saved: SavedSession, now: Date = Date()) -> ChatAccount {
        guard autoAccount, let main = accounts.first(where: { $0.configDir == nil }),
              let picked = autoPick(sharingWith: main, now: now)?.account else { return account }
        return picked
    }

    /// Whether a session of `a` goes on under `b`: their sessions are the same
    /// folder (`projects`), as with a mirrored account (`AccountMirror`).
    func sharesSessions(_ a: ChatAccount, _ b: ChatAccount) -> Bool {
        guard a != b else { return true }
        func projects(_ account: ChatAccount) -> String {
            account.folder(home: home).appendingPathComponent("projects", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
        }
        return projects(a) == projects(b)
    }

    /// A turn of `session` stopped at its account's limit. With «Авто» on it
    /// goes on under the account with the most left whose sessions it shares,
    /// sending again the message it stopped at and those that waited behind
    /// it; with none — or with an account chosen by hand — it waits, goes on
    /// with the one it stopped at when a limit resets, and the ones behind it
    /// are the person's to send (unsent).
    func reachedTheLimit(_ conversation: Conversation, _ session: ChatSession, resets: Date?) {
        let now = Date()
        let from = session.account
        let until = resets ?? limits[from.name]?.fiveHour?.resetsAt ?? now.addingTimeInterval(3600)
        limits[from.name, default: AccountLimits()].limitedUntil = until
        if autoAccount, let target = autoPick(excluding: [from.name], sharingWith: from, now: now)?.account {
            session.account = target
            restartClaude(conversation, saying: "limit-move:\(from.name)|\(target.name)|\(Int(until.timeIntervalSince1970))") {
                session.sendAgainAfterLimit()
            }
            refreshOtherLimits()
            return
        }
        // Nothing to go to now: on again at the first reset that frees one.
        session.keepHeldAsUnsent()
        let candidates = autoAccount ? accounts.filter { sharesSessions(from, $0) } : [from]
        let wake = candidates.compactMap { candidate -> Date? in
            candidate == from ? until : limits[candidate.name]?.limitedUntil
        }.filter { $0 > now }.min() ?? until
        session.note((autoAccount ? "limit-wait:" : "limit-stop:") + "\(from.name)|\(Int(wake.timeIntervalSince1970))")
        waitingForLimit[conversation.id]?.cancel()
        waitingForLimit[conversation.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(30, wake.timeIntervalSince(Date()) + 30)))
            guard !Task.isCancelled, let self else { return }
            waitingForLimit[conversation.id] = nil
            guard conversations.contains(where: { $0.id == conversation.id }), session.state == .idle else { return }
            let target = autoAccount ? (autoPick(sharingWith: session.account)?.account ?? session.account) : session.account
            if target != session.account {
                session.account = target
                restartClaude(conversation, saying: "account:" + target.name) { session.sendAgain() }
            } else {
                limits[target.name]?.limitedUntil = nil
                session.sendAgain()
            }
            render()
        }
    }

    // MARK: - Probes

    /// Starts asking accounts without a session for their limits: now, and
    /// every quarter of an hour.
    func watchLimits() {
        guard probeLoop == nil, accounts.count > 1 else { return }
        probeLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOtherLimits(force: false)
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Asks every account no session runs on for its limits, unless it was
    /// asked lately.
    func refreshOtherLimits(force: Bool = true) {
        Task { await refreshOtherLimits(force: force) }
    }

    func refreshOtherLimits(force: Bool) async {
        let now = Date()
        for account in accounts {
            let busy = conversations.contains { $0.claude?.account == account && !($0.claude?.isEnded ?? true) }
            guard !busy, !probing.contains(account.name) else { continue }
            if !force, let at = probedAt[account.name], now.timeIntervalSince(at) < 10 * 60 { continue }
            probing.insert(account.name)
            probedAt[account.name] = now
            if let usage = await probe(account) {
                limits[account.name, default: AccountLimits()].note(usage, at: Date())
                render()
            }
            probing.remove(account.name)
        }
    }

    /// An account's limits, asked of a short run of `claude` under it:
    /// `initialize` and `get_usage`, no message, nothing spent. Without the
    /// user's settings — their hooks would run for it — and without a
    /// transcript, in a folder of its own.
    func probe(_ account: ChatAccount) async -> ClaudeUsage? {
        let environment = account.environment(from: await environment())
        guard let (executable, prefix) = program("claude", setting: "UDECK_SETTING_CLAUDE", path: environment["PATH"] ?? "")
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = prefix + ClaudeOutbound.arguments() + ["--setting-sources", "project", "--no-session-persistence"]
        guard let process = try? AgentProcess(executable: executable, arguments: arguments, environment: environment,
                                              directory: folder) else { return nil }
        let connection = ClaudeCodeConnection(channel: process)
        await connection.start()
        defer { Task { _ = await connection.close(grace: .seconds(2)) } }
        guard (try? await connection.request({ ClaudeOutbound.initialize(id: $0) }, timeout: .seconds(30))) != nil,
              let answer = try? await connection.request({ ClaudeOutbound.usage(id: $0) }, timeout: .seconds(20)),
              answer.succeeded
        else { return nil }
        return ClaudeUsage(answer.body)
    }
}
