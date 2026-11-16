import AppKit
import Foundation
import UDeckCore

/// What a **Sign in** is doing, or came to (S4-23).
public enum SignIn: Equatable, Sendable {
    /// Asking `host` for a code.
    case asking(host: String)
    /// The code to enter, the page it is entered on — `shown` as the host
    /// named it, `page` what **Copy the code and open…** opens — and the
    /// host asked, at its interval, whether it was.
    case code(userCode: String, page: URL, shown: String, host: String)
    /// Signed in: the repository being read with the new token.
    case checking(host: String)
    /// Signed in, and the GitHub repository answered `404`: the uDeck app is
    /// not installed where it is — the sentence, and the page that installs it.
    case notInstalled(Phrase, install: URL?)
    /// Why it got no token, or why the token did not read the repository.
    case failed(Phrase)

    /// Whether it is under way.
    public var isUnderWay: Bool {
        switch self {
        case .asking, .code, .checking: true
        case .notInstalled, .failed: false
        }
    }
}

extension DeckModel {
    // MARK: - Whether Sign in is offered

    /// The application **Sign in** asks as for a repository of `provider` on
    /// `host` — `pasted` a GitLab of one's own's id — or nil, and no button.
    public func signInClientID(provider: String, host: String, pasted: String?) -> String? {
        guard sourceClients.oauth(provider: provider, host: host) != nil else { return nil }
        return signInApps.clientID(provider: provider, host: host, pasted: pasted)
    }

    /// Whether `host` is a GitLab of one's own: Sign in there asks as an
    /// application the person registered, whose id they paste.
    public func asksForAnApplicationID(provider: String, host: String) -> Bool {
        provider == SourceLink.gitlab && host != SourceLink.gitLabCom
    }

    /// The id a GitLab of one's own's Sign in would ask as now, under the
    /// step `key`: what is pasted in its field, or what `sources.json` keeps.
    func pastedApplicationID(_ key: String) -> String? {
        if key.isEmpty { return addSourceDraft?.applicationID }
        let pasted = sourceApplicationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return pasted.isEmpty ? source(key)?.signInClientID : pasted
    }

    // MARK: - Signing in

    /// **Sign in** under the step `key` — a source's **Token…** by its id,
    /// or `""` for **Add a source…**'s token step (S4-23): a code asked of
    /// the host's OAuth endpoints, shown, and the host asked at its interval
    /// whether the person entered it; then the repository read with the
    /// token, and the token kept only once it read it. uDeck never opens the
    /// browser by itself. Nothing when this build has no application for the
    /// host, or the step is gone.
    public func signIn(_ key: String) {
        let target: (provider: String, host: String)
        if key.isEmpty {
            guard let draft = addSourceDraft else { return }
            target = (draft.link.provider, draft.link.host)
        } else {
            guard let source = source(key), sourcesProblem == nil, !sourcesForgetting.contains(key) else { return }
            target = (source.provider, source.host)
        }
        let pasted = pastedApplicationID(key)
        guard let clientID = signInClientID(provider: target.provider, host: target.host, pasted: pasted),
              let endpoints = sourceClients.oauth(provider: target.provider, host: target.host) else { return }
        // A GitLab of one's own's id is written as Sign in is pressed with it.
        if !key.isEmpty, asksForAnApplicationID(provider: target.provider, host: target.host),
           SignInApps.cleaned(pasted) != source(key)?.signInClientID {
            do {
                try sourceStore.modify { list in _ = list.setSignInClientID(key, pasted) }
            } catch {
                sourceOperationProblems[key] = "\(error)"
            }
            loadSources()
        }
        cancelSignIn(key)
        sourceNotices[key] = nil
        // The turn to change the source's token, from this press on: a token
        // check under way loses it, and one pressed after takes it from this.
        if !key.isEmpty {
            signInTickets[key] = sourceTokens.begin(key)
            sourceTokenChecks[key]?.cancel()
            sourceTokenChecks[key] = nil
        }
        signIns[key] = .asking(host: target.host)
        let client = OAuthClient(endpoints: endpoints, clientID: clientID, udeckVersion: udeckVersion,
                                 session: sourceClients.session)
        DeckLog.plugins.info("signing in at \(endpoints.host, privacy: .public) for \(key.isEmpty ? "a source being added" : key, privacy: .public)")
        signInTasks[key] = Task { [weak self] in
            let code: DeviceCode
            do throws(SignInError) {
                code = try await client.deviceCode()
            } catch {
                guard !Task.isCancelled else { return }
                self?.signInFailed(key, error, host: target.host)
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.signIns[key] = .code(userCode: code.userCode, page: code.pageToOpen,
                                      shown: code.pageToOpen.absoluteString, host: target.host)
            var polling = DevicePolling(code)
            var step = polling.first
            while case .wait(let seconds) = step {
                try? await Task.sleep(nanoseconds: Seconds.nanoseconds(seconds))
                guard !Task.isCancelled else { return }
                step = polling.next(await client.poll(code), now: Date())
            }
            guard !Task.isCancelled else { return }
            switch step {
            case .signedIn(let tokens):
                let binding = CredentialBinding(provider: target.provider, remoteID: 0,
                                                apiOrigin: self.apiOrigin(provider: target.provider, host: target.host)
                                                    ?? endpoints.origin,
                                                oauthOrigin: endpoints.origin)
                self.signedInTokens[key] = SourceCredential(tokens, clientID: clientID, binding: binding)
                DeckLog.plugins.info("signed in at \(endpoints.host, privacy: .public): checking the repository")
                await self.checkSignedIn(key)
            case .failed(let error):
                self.signInFailed(key, error, host: target.host)
            case .wait:
                break
            }
        }
    }

    /// The API origin a repository of `provider` on `host` is read at in
    /// this build — what a token from Sign in is bound to.
    func apiOrigin(provider: String, host: String) -> Origin? {
        provider == SourceLink.github ? Origin(endpoints.apiBase) : sourceClients.gitLab(host).flatMap { Origin($0.apiBase) }
    }

    private func signInFailed(_ key: String, _ error: SignInError, host: String) {
        DeckLog.plugins.info("sign-in at \(host, privacy: .public) came to nothing: \(error.description, privacy: .public)")
        signIns[key] = .failed(SignInTrouble.phrase(error, host: host))
    }

    /// The Sign in under the step `key` stopped — its step closed, the
    /// source forgotten or removed — and what it said gone.
    public func cancelSignIn(_ key: String) {
        signInTasks[key]?.cancel()
        signInTasks[key] = nil
        signIns[key] = nil
        signedInTokens[key] = nil
        signInTickets[key] = nil
    }

    /// **Copy the code and open…**: the code on the clipboard and the page
    /// opened — by the person's press, never by uDeck by itself.
    public func copyCodeAndOpen(_ key: String) {
        guard case .code(let userCode, let page, _, _)? = signIns[key] else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(userCode, forType: .string)
        NSWorkspace.shared.open(page)
    }

    /// **Look up again**, once the uDeck app is installed: the token Sign in
    /// got read with again — no new code to enter.
    public func lookUpAgain(_ key: String) {
        guard signedInTokens[key] != nil, signInTasks[key] == nil || signIns[key]?.isUnderWay == false else { return }
        signInTasks[key]?.cancel()
        signInTasks[key] = Task { [weak self] in await self?.checkSignedIn(key) }
    }

    // MARK: - The token Sign in got

    /// The token Sign in got under `key`, read with: for **Add a source…**,
    /// the look-up of the address, by its path (`SourceLookUp`) — **Add**
    /// keeps it; for a source's **Token…**, its repository by its number,
    /// and the token kept once it read it, the source read with it from then
    /// on (`access` *signIn*). A GitHub repository's `404` says to install the
    /// uDeck app, and **Look up again** reads with the same token after.
    func checkSignedIn(_ key: String) async {
        guard var credential = signedInTokens[key] else { return }
        // Whatever stops the check before it says something, it says nothing:
        // never a step left reading.
        defer { if case .checking? = signIns[key] { signIns[key] = nil } }
        let host = credential.binding.provider == SourceLink.github ? SourceLink.githubHost
            : (key.isEmpty ? addSourceDraft?.link.host : source(key)?.host) ?? ""
        signIns[key] = .checking(host: host)
        if key.isEmpty {
            guard let draft = addSourceDraft else { return }
            sourceLookups += 1
            let asked = sourceLookups
            let came = await SourceLookUp.lookUp(draft.link, list: sourceList, official: catalogueAddress,
                                                 officialID: endpoints.repositoryID, clients: sourceClients,
                                                 signedIn: credential)
            persistRateLimit()
            guard asked == sourceLookups, !Task.isCancelled else { return }
            DeckLog.plugins.info("the source signed in to came to \(String(describing: came), privacy: .public)")
            if case .refused(let phrase) = came, case .sourceSignInAppNotInstalled = phrase {
                signIns[key] = .notInstalled(phrase, install: signInApps.installPage)
                return
            }
            signInTasks[key] = nil
            signIns[key] = nil
            sourceAddingTokened = true
            sourceAdding = .came(came)
            if case .found = came { addSourceDraft = nil }
            return
        }
        guard let source = source(key), sourcesProblem == nil, !sourcesForgetting.contains(key) else { return }
        credential.binding.remoteID = source.remoteID
        guard let provider = sourceClients.of(source, credential: credential) else { return }
        do {
            _ = try await provider.describeWithScopes()
        } catch {
            guard !Task.isCancelled, signedInTokens[key] != nil else { return }
            if source.provider == SourceLink.github, case ProviderError.notFound = error {
                let parts = source.path.split(separator: "/", maxSplits: 1).map(String.init)
                signIns[key] = .notInstalled(.sourceSignInAppNotInstalled(owner: parts.first ?? source.path,
                                                                          repository: parts.count > 1 ? parts[1] : source.path),
                                             install: signInApps.installPage)
                return
            }
            let reason = CatalogueRefresher.reason(error, branch: nil, tokened: true)
            signIns[key] = .failed(CatalogueTrouble.phrase(reason, address: source.address.description, host: source.host,
                                                           readAt: nil, until: { Clock.text($0, self.strings) },
                                                           provider: source.provider, tokened: true))
            return
        }
        guard !Task.isCancelled, signedInTokens[key] != nil, let now = self.source(key),
              now.remoteID == source.remoteID, let ticket = signInTickets[key] else { return }
        await keepSignedIn(credential, for: now, ticket: ticket)
    }

    /// A token Sign in got, that read its source's repository, kept — the
    /// Keychain first, then `sources.json` says *signIn* — and the source read
    /// with it. Its turn lost meanwhile — Forget, Remove, another token —
    /// and it is taken back, as a pasted token is (`keepToken`).
    private func keepSignedIn(_ credential: SourceCredential, for source: OwnSource,
                              ticket: SourceTokenBook.Ticket) async {
        let id = source.id
        // A token pasted, forgotten or removed since Sign in was pressed.
        guard sourceTokens.isCurrent(ticket) else {
            signIns[id] = nil
            return
        }
        sourcesKeeping[id] = ticket
        defer { if sourcesKeeping[id] == ticket { sourcesKeeping[id] = nil } }
        let revision: Int
        do throws(CredentialVault.ChangeError) {
            revision = try await credentialVault.keep(credential, for: id)
        } catch {
            guard sourceTokens.isCurrent(ticket) else { return }
            signIns[id] = .failed(.sourceKeychainUnavailable(address: source.address.description, reason: Self.said(error)))
            return
        }
        // A token replaced leaves `sources.json` as it is — it already says
        // the source has one — so a failed write never costs the token it
        // replaced; *signIn* is written after, as far as the file lets it. A
        // first token writes it, or is taken back.
        var written = false
        var problem: String?
        let replacing = (self.source(id)?.access ?? OwnSource.Access.none) != OwnSource.Access.none
        if sourceTokens.isCurrent(ticket), self.source(id) != nil {
            if replacing {
                written = true
            } else {
                do {
                    written = try sourceStore.modify { list in list.setAccess(id, OwnSource.Access.signIn) }
                } catch {
                    problem = "\(error)"
                }
            }
        }
        if written { startTheLimitOfANewToken(id) }
        loadSources()
        // A new Sign in: a renewal of its own, never one of the pair before.
        tokenRenewals[id] = nil
        var held = credential
        held.renewal = await renewal(for: id, held)
        guard written, sourceTokens.hold(held, for: ticket, renewingRejected: true) != nil else {
            await takeBack(id, written: revision, address: source.address.description)
            if let problem, sourceTokens.isCurrent(ticket) { sourceOperationProblems[id] = problem }
            signIns[id] = nil
            return
        }
        retiredRefreshTokens[id] = nil
        if replacing, self.source(id)?.access != OwnSource.Access.signIn {
            do {
                try sourceStore.modify { list in _ = list.setAccess(id, OwnSource.Access.signIn) }
            } catch {
                sourceOperationProblems[id] = "\(error)"
            }
            loadSources()
        }
        DeckLog.plugins.info("signed in for \(id, privacy: .public): the token is kept")
        signedInTokens[id] = nil
        signInTasks[id] = nil
        signInTickets[id] = nil
        signIns[id] = nil
        sourceNotices[id] = [.sourceSignedIn(host: source.host)]
        if sourceTokenOpen == id {
            sourceTokenDraft = ""
            sourceApplicationDraft = ""
            sourceTokenOpen = nil
        }
        await refreshSource(id, unrequested: false, pressed: true, why: "signed in")
    }

    // MARK: - Renewing

    /// The renewal of the token `credential` — Sign in's, of the source `id`
    /// — shared by every client holding it: the one already made for its
    /// refresh token, or a new one, which renews at the host's OAuth origin
    /// it was signed in at and no other, asks the Keychain first, and writes
    /// the new pair there — read, changed, written — before the new token is
    /// sent (S4-23). Nil for a pasted token, and one with no refresh token.
    func renewal(for id: String, _ credential: SourceCredential) async -> TokenRenewal? {
        guard credential.kind == .oauth, credential.refresh != nil, let clientID = credential.clientID,
              let source = source(id), let endpoints = sourceClients.oauth(of: source) else { return nil }
        // One renewal per source: whatever pair a lookup brought, the one
        // made already adopts it — never a second that would go stale.
        if let made = tokenRenewals[id], made.clientID == clientID, made.signedInAt == credential.binding.oauthOrigin {
            await made.adopt(credential.tokens)
            return made
        }
        let client = OAuthClient(endpoints: endpoints, clientID: clientID, udeckVersion: udeckVersion,
                                 session: sourceClients.session)
        let signedInAt = credential.binding.oauthOrigin
        let vault = credentialVault
        let renewal = TokenRenewal(
            credential.tokens, clientID: clientID, signedInAt: signedInAt,
            renew: { refresh throws(SignInError) in try await client.renew(refresh, boundTo: signedInAt) },
            check: { refresh in await vault.mayRenew(id, with: refresh) },
            keep: { [weak self] old, new in
                do throws(CredentialVault.ChangeError) {
                    try await vault.rotate(id, from: old, to: new)
                } catch {
                    DeckLog.plugins.error("\(id, privacy: .public): the renewed token could not be kept: \(Self.said(error), privacy: .public)")
                    return Self.said(error)
                }
                await self?.renewed(id, from: old, to: new)
                return nil
            })
        tokenRenewals[id] = renewal
        return renewal
    }

    /// Sign in's pair renewed and kept: every client holding the token sends
    /// the new one, under the same lease.
    func renewed(_ id: String, from old: Secret, to new: OAuthTokens) {
        DeckLog.plugins.info("\(id, privacy: .public): its token from Sign in was renewed")
        retiredRefreshTokens[id, default: []].append(old)
        sourceTokens.renewed(id, from: old, to: new)
    }
}
