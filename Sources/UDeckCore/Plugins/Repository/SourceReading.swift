import Foundation

// Reading the sources the operator adds (stage 4): the client a source is read
// through, the official repository's number checked at its describe, Look up
// before Add, when each source is read, what may be read at all, and what a
// read that did not finish says. Decided here, where it is tested; DeckModel
// only says when, and shows what came of it. See docs/plugin-repository.md,
// "Sources of one's own".

// MARK: - The official repository's number

/// The official source as it is read: by its path, as in stage 3 — its forks
/// are found by theirs — and held, at every describe, to the number this uDeck
/// knows it by (`GitHubEndpoints.repositoryID`, `UDeckPluginsRepositoryID`). A
/// describe is what the catalogue's read makes once a day, for the default
/// branch (`CatalogueRefresher`), and what **Install from a link…** makes when
/// the catalogue was never read. One that answers another number — or none —
/// is the official address belonging to a different repository now: the read
/// stops with `CatalogueError.officialRepositoryChanged`, before anything of
/// that repository is read, and nothing of it updates by itself.
///
/// Nothing else is changed: every other question goes to the official client
/// as it is, a fork's client is the official client's (`provider(for:)`) and
/// is never held to the official number, and with no number given nothing is
/// compared.
public struct OfficialRepositoryCheck: RepositoryProvider {
    public let client: GitHubClient
    /// The number the describe has to answer; nil compares nothing.
    public let expected: Int?

    public init(_ client: GitHubClient, expected: Int?) {
        self.client = client
        self.expected = expected
    }

    public var address: RepositoryAddress { client.address }

    public func defaultBranch() async throws -> String {
        try await describe().defaultBranch
    }

    public func describe() async throws -> RepositoryDescription {
        let description = try await client.describe()
        if let expected, description.id != expected { throw CatalogueError.officialRepositoryChanged }
        return description
    }

    public func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer {
        try await client.head(of: branch, ifNoneMatch: etag)
    }

    public func tree(_ sha: String, recursive: Bool) async throws -> GitTree {
        try await client.tree(sha, recursive: recursive)
    }

    public func file(at path: String, commit: String) async throws -> Data {
        try await client.file(at: path, commit: commit)
    }

    public func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
        try await client.commits(touching: path, on: branch)
    }

    public func pull(_ number: Int) async throws -> PullRequest {
        try await client.pull(number)
    }

    public func compare(_ base: String, _ head: String) async throws -> Comparison {
        try await client.compare(base, head)
    }

    public func folderPage(_ path: String, commit: String) -> URL? {
        client.folderPage(path, commit: commit)
    }

    public func comparePage(from: String, to: String) -> URL? {
        client.comparePage(from: from, to: to)
    }

    public func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? {
        repository == client.address ? self : client.provider(for: repository)
    }
}

// MARK: - A source's own client

/// What a source of one's own is read through, for one read or one press: its
/// client addressed by its number — GitHub's `/repositories/{id}`
/// (`GitHubClient.Addressing.id`), GitLab's `/projects/{id}` (`GitLabClient`)
/// — so that nothing after **Look up** asks for it by a name; and, once a
/// describe by that number says the repository is called something else now,
/// that name from then on, for its raw files and its pages (`renamedTo`, which
/// the caller writes back to `sources.json`). A describe that answers for
/// another number than the source's is not believed.
///
/// Its own repository only: `provider(for:)` answers itself for its own
/// address — whatever its case on GitHub, byte for byte on GitLab — and
/// nothing for any other: never another repository's files under its number.
public final class SourceProvider: RepositoryProvider, @unchecked Sendable {
    /// The client underneath: GitHub's or GitLab's.
    enum Client: Sendable {
        case github(GitHubClient)
        case gitlab(GitLabClient)

        var provider: any RepositoryProvider {
            switch self {
            case .github(let client): client
            case .gitlab(let client): client
            }
        }

        func renamed(to path: String) -> Client? {
            switch self {
            case .github(let client): client.renamed(to: path).map(Client.github)
            case .gitlab(let client): client.renamed(to: path).map(Client.gitlab)
            }
        }

        func isOwn(_ repository: RepositoryAddress) -> Bool {
            switch self {
            case .github(let client): client.client(for: repository) != nil
            case .gitlab(let client): client.provider(for: repository) != nil
            }
        }
    }

    private let lock = NSLock()
    private var client: Client
    private var heard: String?
    /// The number the host knows the repository by.
    public let remoteID: Int

    /// `client` must be addressed by id; one addressed by path is refused.
    public init?(_ client: GitHubClient) {
        guard case .id(let id) = client.addressing else { return nil }
        self.client = .github(client)
        self.remoteID = id
    }

    /// A GitLab project, which its client always addresses by its number.
    public init(_ client: GitLabClient) {
        self.client = .gitlab(client)
        self.remoteID = client.remoteID
    }

    private var current: any RepositoryProvider { lock.withLock { client.provider } }

    public var address: RepositoryAddress { current.address }

    /// The path a describe said the repository is at now, when it said
    /// another than the one this was made with — nil otherwise.
    public var renamedTo: String? { lock.withLock { heard } }

    public func describe() async throws -> RepositoryDescription {
        let asked = lock.withLock { client }
        let description = try await asked.provider.describe()
        if let id = description.id, id != remoteID {
            throw ProviderError.badAnswer("the repository asked for as \(remoteID) answered as \(id)")
        }
        if let name = description.fullName, name != asked.provider.address.path, let renamed = asked.renamed(to: name) {
            lock.withLock {
                client = renamed
                heard = name
            }
        }
        return description
    }

    public func defaultBranch() async throws -> String {
        try await describe().defaultBranch
    }

    public func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer {
        try await current.head(of: branch, ifNoneMatch: etag)
    }

    public func tree(_ sha: String, recursive: Bool) async throws -> GitTree {
        try await current.tree(sha, recursive: recursive)
    }

    public func file(at path: String, commit: String) async throws -> Data {
        try await current.file(at: path, commit: commit)
    }

    public func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
        try await current.commits(touching: path, on: branch)
    }

    public func pull(_ number: Int) async throws -> PullRequest {
        try await current.pull(number)
    }

    public func compare(_ base: String, _ head: String) async throws -> Comparison {
        try await current.compare(base, head)
    }

    public func folderPage(_ path: String, commit: String) -> URL? {
        current.folderPage(path, commit: commit)
    }

    public func comparePage(from: String, to: String) -> URL? {
        current.comparePage(from: from, to: to)
    }

    public func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? {
        lock.withLock { client }.isOwn(repository) ? self : nil
    }
}

/// How the clients of sources are made. A GitHub source's: the official
/// source's API and raw host — the lab's fake in a lab build — and, asked
/// without a token, the official source's limit: GitHub counts what an
/// address asks without a token whatever the repository (S4-16), so an
/// anonymous source does not have sixty an hour of its own. A GitLab
/// source's: its host's API — or the base `UDeckPluginsHostMap` gives it in a
/// test build — and a limit of its own (`gitLabLimits`, by the source's id),
/// seeded from and kept in its `state.json`: GitLab counts by limiters of its
/// own, which a GitHub block must not stop. Two anonymous gitlab.com sources
/// each keep their own count, though the network's is one; that is accepted.
public struct SourceClients: Sendable {
    public var endpoints: GitHubEndpoints
    public var udeckVersion: String
    public var limits: RateLimitRecorder
    public var session: URLSession
    /// `UDeckPluginsHostMap`'s hosts and bases (`HostMap`).
    public var hostMap: [String: URL]
    /// Each GitLab source's limit, by its id; one not here is read with a
    /// fresh one.
    public var gitLabLimits: [String: RateLimitRecorder]

    public init(endpoints: GitHubEndpoints, udeckVersion: String, limits: RateLimitRecorder,
                session: URLSession = GitHubClient.makeSession(), hostMap: [String: URL] = [:],
                gitLabLimits: [String: RateLimitRecorder] = [:]) {
        self.endpoints = endpoints
        self.udeckVersion = udeckVersion
        self.limits = limits
        self.session = session
        self.hostMap = hostMap
        self.gitLabLimits = gitLabLimits
    }

    /// A GitLab host's endpoints, as this build reads it.
    public func gitLab(_ host: String) -> GitLabEndpoints? {
        GitLabEndpoints.of(host, hostMap: hostMap)
    }

    /// What **Look up** of a GitLab project on `host` is counted against,
    /// before the project is a source with a limit of its own: the host's,
    /// kept while uDeck runs (`lookUpLimits`), which **Add** seeds the new
    /// source's from — a fresh one for a host not given.
    public var lookUpLimits: [String: RateLimitRecorder] = [:]

    public func lookUpLimits(for host: String) -> RateLimitRecorder {
        lookUpLimits[host] ?? RateLimitRecorder()
    }

    func client(_ path: String, addressing: GitHubClient.Addressing) -> GitHubClient {
        var endpoints = self.endpoints
        endpoints.repository = path
        endpoints.repositoryID = nil
        return GitHubClient(endpoints: endpoints, udeckVersion: udeckVersion, limits: limits, session: session,
                            addressing: addressing)
    }

    /// The one request ever addressed by a name: **Look up**'s describe.
    public func byPath(_ path: String) -> GitHubClient {
        client(path, addressing: .path)
    }

    /// A source's provider (`SourceProvider`), by its number: a github.com
    /// repository's, or a GitLab project's on its own host — nil for a host
    /// no address could name.
    public func of(_ source: OwnSource) -> SourceProvider? {
        switch source.provider {
        case SourceLink.github:
            guard source.host == SourceLink.githubHost else { return nil }
            return SourceProvider(client(source.path, addressing: .id(source.remoteID)))
        case SourceLink.gitlab:
            guard let endpoints = gitLab(source.host) else { return nil }
            return SourceProvider(GitLabClient(endpoints: endpoints, path: source.path, remoteID: source.remoteID,
                                               udeckVersion: udeckVersion,
                                               limits: gitLabLimits[source.id] ?? RateLimitRecorder(),
                                               session: session))
        default:
            return nil
        }
    }

    /// The limit a source is counted against: GitHub's anonymous one, which
    /// the official source has, or a GitLab source's own.
    public func limits(of source: OwnSource) -> RateLimitRecorder {
        source.provider == SourceLink.gitlab ? gitLabLimits[source.id] ?? RateLimitRecorder() : limits
    }

    /// The provider of the repository `path` is at now, by its number.
    public func byID(_ id: Int, path: String) -> SourceProvider? {
        SourceProvider(client(path, addressing: .id(id)))
    }
}

// MARK: - Look up

/// **Look up** in **Add a source…**: an address read as a browser shows it
/// (`SourceLink`) — a refusal said before any request — then asked of its
/// host, anonymously. For a github.com repository: `GET /repos/{o}/{r}`, the
/// one request ever addressed by its name, which says its number, its name as
/// GitHub spells it and its default branch; that branch's head by the number,
/// `GET /repositories/{id}/commits/{branch}`; and the passport at that commit,
/// from the raw host — two requests to the API and one to the raw host. For a
/// GitLab project: `GET /api/v4/projects/{group%2Fproject}`, the one request
/// ever addressed by its path, which says its number, its path as GitLab spells
/// it and its default branch; `GET /projects/{id}/repository/branches/{branch}`;
/// and the passport at that commit, `GET
/// /projects/{id}/repository/files/udeck-plugins.json/raw?ref={commit}` —
/// three requests to the API, as GitLab has no raw host to read. What it comes
/// to is what the sheet shows, and **Add** adds only what it found.
public enum SourceLookUp {
    /// A repository with a passport at its default branch's head: what **Add**
    /// writes, and what the sheet shows of it.
    public struct Found: Equatable, Sendable {
        public var provider: String
        public var host: String
        /// As the host spells it now.
        public var path: String
        public var remoteID: Int
        public var defaultBranch: String
        public var head: String
        public var passport: RepositoryPassport
        /// The passport's bytes, which **Add** keeps in the source's blob store.
        public var passportData: Data
        /// When the host answered: what the source's state says the default
        /// branch was read at.
        public var readAt: Date
        /// What a GitLab's limiters said by the end of **Look up**: what the
        /// source's own limit starts from (S4-16). Nil for GitHub, whose
        /// anonymous limit is the official source's.
        public var rateLimit: RateLimitState? = nil

        public var address: RepositoryAddress { RepositoryAddress(provider: provider, host: host, path: path) }
        public var identity: SourceIdentity { SourceIdentity(provider: provider, host: host, remoteID: remoteID) }
    }

    /// What **Look up** comes to.
    public enum Outcome: Equatable, Sendable {
        /// Found, and **Add** is offered.
        case found(Found)
        /// The same repository is added already: its block, by its id.
        case alreadyAdded(OwnSource)
        /// No passport at the top of the default branch: *"… is not a uDeck
        /// plugin repository"*, and nothing is offered.
        case notAPluginRepository(address: String, branch: String)
        /// Nothing to add, and why.
        case refused(Phrase)
        /// A request that got no good answer — the limit, the network, an
        /// answer that could not be read — said as a source's read says it,
        /// of the address as it was read (`SourceLink`), not as it was pasted,
        /// on the host's provider.
        case failed(CatalogueError, host: String, address: String, provider: String = SourceLink.github)
    }

    /// What an address pasted comes to before anything is asked.
    public enum Pasted: Equatable, Sendable {
        /// A repository to ask its host about.
        case link(SourceLink)
        /// Why it is not read.
        case refused(Phrase)
    }

    /// What `text` names, before anything is asked: the address, or why it is
    /// not read.
    public static func read(_ text: String, official: RepositoryAddress) -> Pasted {
        switch SourceLink.read(text, official: official) {
        case .failure(let refusal): .refused(.sourceLinkRefused(refusal, official: official.description))
        case .success(let link): .link(link)
        }
    }

    /// `link` asked of its host through `clients`, `list` being the sources
    /// added, `official` the official repository and `officialID` its number.
    public static func lookUp(_ link: SourceLink, list: SourceList, official: RepositoryAddress, officialID: Int?,
                              clients: SourceClients,
                              now: @escaping @Sendable () -> Date = { Date() }) async -> Outcome {
        let address = link.address.description
        let gitLab = link.provider == SourceLink.gitlab
        func failed(_ error: any Error, branch: String?, at address: String) -> Outcome {
            .failed(CatalogueRefresher.reason(error, branch: branch), host: link.host, address: address,
                    provider: link.provider)
        }
        let description: RepositoryDescription
        if gitLab {
            guard let endpoints = clients.gitLab(link.host) else {
                return .refused(.sourceLinkRefused(.notALink, official: official.description))
            }
            do {
                switch try await GitLabClient.lookUp(link.path, endpoints: endpoints, udeckVersion: clients.udeckVersion,
                                                     limits: clients.lookUpLimits(for: link.host), session: clients.session,
                                                     now: now) {
                case .found(let found): description = found
                case .notFound: return .refused(.sourceNotFound(address: address))
                case .notGitLab: return .refused(.sourceNotGitLab(host: link.host))
                }
            } catch {
                return failed(error, branch: nil, at: address)
            }
        } else {
            do {
                description = try await clients.byPath(link.path).describe()
            } catch ProviderError.notFound {
                return .refused(.sourceNotFound(address: address))
            } catch {
                return failed(error, branch: nil, at: address)
            }
        }
        guard let id = description.id else {
            return .failed(.badAnswer("the repository's description has no number"), host: link.host, address: address,
                           provider: link.provider)
        }
        // The host's own spelling of it, when it gives one this uDeck reads as
        // the same provider's name — the official repository's included,
        // whatever was pasted.
        var path = link.path
        if let name = description.fullName {
            let spelt = gitLab ? SourceLink.refusal(of: link.address.with(path: name), official: official) == nil
                               : clients.byPath(name).client(for: link.address.with(path: name)) != nil
            if spelt { path = name }
        }
        let named = SourceLink(provider: link.provider, host: link.host, path: path)
        if !gitLab, id == officialID || SourceLink.refusal(of: named.address, official: official) == .officialCatalogue {
            return .refused(.sourceLinkRefused(.officialCatalogue, official: official.description))
        }
        // What Add would come to, asked now, so that the sheet offers it only
        // when it would add the source.
        var trial = list
        switch trial.add(provider: named.provider, host: named.host, path: path, remoteID: id, at: now(), official: official) {
        case .success: break
        case .failure(.alreadyAdded(let source)): return .alreadyAdded(source)
        case .failure(.idTaken(let taken)): return .refused(.sourceIDTaken(name: taken.address.description))
        case .failure(.address(let refusal)): return .refused(.sourceLinkRefused(refusal, official: official.description))
        case .failure(.listedAsSkipped(let skipped)): return .refused(.sourceSkipped(skipped))
        }
        let spelt = named.address.description
        let byID: SourceProvider?
        if gitLab, let endpoints = clients.gitLab(link.host) {
            byID = SourceProvider(GitLabClient(endpoints: endpoints, path: path, remoteID: id,
                                               udeckVersion: clients.udeckVersion,
                                               limits: clients.lookUpLimits(for: link.host), session: clients.session,
                                               now: now))
        } else {
            byID = gitLab ? nil : clients.byID(id, path: path)
        }
        guard let byID else {
            return .failed(.badAnswer("no client for the repository's number"), host: link.host, address: spelt,
                           provider: link.provider)
        }
        let branch = description.defaultBranch
        let head: String
        do {
            switch try await byID.head(of: branch, ifNoneMatch: nil) {
            case .commit(let commit, _): head = commit
            case .unchanged:
                return .failed(.badAnswer("the head of \(branch) was answered as unchanged"), host: link.host,
                               address: spelt, provider: link.provider)
            }
        } catch {
            return failed(error, branch: branch, at: spelt)
        }
        let data: Data
        do {
            data = try await byID.file(at: RepositoryPassport.path, commit: head)
        } catch ProviderError.notFound {
            return .notAPluginRepository(address: spelt, branch: branch)
        } catch {
            return failed(error, branch: branch, at: spelt)
        }
        switch RepositoryPassport.read(data) {
        case .success(let passport):
            return .found(Found(provider: named.provider, host: named.host, path: path, remoteID: id, defaultBranch: branch,
                                head: head, passport: passport, passportData: data, readAt: now(),
                                rateLimit: gitLab ? clients.lookUpLimits(for: link.host).current : nil))
        case .failure(.missing):
            return .notAPluginRepository(address: named.address.description, branch: branch)
        case .failure(.futureFormat(let declared)):
            return .refused(.catalogueFutureFormat(declared: declared))
        case .failure(.invalid(let reason)):
            return .refused(.catalogueInvalidPassport(source: named.address.description, reason: reason))
        }
    }

    /// A source's first state, from what **Look up** heard: its default
    /// branch and when — so that the read right after **Add** does not ask
    /// for it again — and, of a GitLab, what its limiters said.
    public static func firstState(of found: Found) -> CatalogueState {
        CatalogueState(defaultBranch: found.defaultBranch, defaultBranchReadAt: found.readAt,
                       rateLimit: found.rateLimit ?? RateLimitState())
    }
}

extension RepositoryLink {
    /// The repository other than the official one a link names — a branch of
    /// it, or its own page — which may be a source of one's own; nil for the
    /// official repository's own links.
    public var otherRepository: RepositoryAddress? {
        switch self {
        case .forkBranch(let address, _, _), .forkRepository(let address): address
        case .officialRepository, .pullRequest, .branch: nil
        }
    }

    /// Whether `text`, read as **Install from a link…** reads it, is a link
    /// into a source of one's own among `sources` — a branch, its page, or a
    /// pull request; of a GitLab project, a branch, its page or a merge
    /// request, read as **Add a source…** reads it (`SourceLink`) — which is
    /// not installed from yet (`Phrase.sourceBranchNotYet`).
    public static func namesASource(_ text: String, official: RepositoryAddress, sources: [OwnSource]) -> Bool {
        let named: RepositoryAddress?
        switch read(text, official: official) {
        case .success(let link): named = link.otherRepository
        case .failure(.otherRepositoryPullRequest(let address, _)): named = address
        case .failure(.notGitHub), .failure(.notALink):
            // Another host's — a host with a port is no link here — which
            // may be a GitLab project added as a source.
            guard case .success(let link) = SourceLink.read(text, official: official),
                  link.provider == SourceLink.gitlab else { return false }
            named = link.address
        case .failure: named = nil
        }
        guard let named else { return false }
        return sources.contains { $0.isAt(named) }
    }
}

extension RepositoryAddress {
    /// The same provider and host, at `path`.
    func with(path: String) -> RepositoryAddress {
        RepositoryAddress(provider: provider, host: host, path: path)
    }
}

// MARK: - What may be read

/// Whether a source's copies may be asked about at all — read, updated,
/// reinstalled, put back, their history read — (S4-04): the official source's
/// while it may be read (`readsOfficialRepository`); a source of one's own's
/// while it is listed in a `sources.json` that can be read. **Official
/// catalogue** governs the official repository alone.
public enum SourceAccess {
    /// `officialCatalogue` is whether the official repository may be read
    /// now (`readsOfficialRepository`), not the switch alone.
    public static func canRead(_ source: String, officialCatalogue: Bool, sources: [OwnSource]) -> Bool {
        source == InstalledPlugins.officialSource ? officialCatalogue : sources.contains { $0.id == source }
    }

    /// Whether the official repository may be asked anything but its number:
    /// **Official catalogue** on, and its address not another repository's
    /// (S4-13, `CatalogueError.officialRepositoryChanged`, which the
    /// catalogue's `state` keeps until a describe answers the official
    /// number again). Until then nothing of it is installed, updated, put
    /// back, reinstalled or listed — its copies' earlier versions, its links,
    /// its forks, the lines its copies came from — and only the catalogue's
    /// own read asks, for its number, first.
    public static func readsOfficialRepository(officialCatalogue: Bool, state: CatalogueState) -> Bool {
        officialCatalogue && state.lastError != .officialRepositoryChanged
    }

    /// Whether the minute's clock runs at all: while any source can be read.
    public static func clockRuns(officialCatalogue: Bool, sources: [OwnSource]) -> Bool {
        officialCatalogue || !sources.isEmpty
    }
}

// MARK: - A copy's earlier versions

/// A copy's earlier versions as they were read: from the history of the
/// source the copy was of then (S4-12). They stand for the copy only while it
/// is of that source still — a copy switched since, by **Install from here…**,
/// **Switch to verified** or **Back to** across sources, has another source's
/// history, read anew — and a version is installed only from the history read
/// of the copy's own source, and only one that history lists: never a commit
/// of one source through another, recorded as the other's.
public enum EarlierVersions {
    /// Whether `history`, read from the source `readOf`, stands for a copy of
    /// `source` whose source's head is `head` — shown as it is, not read again.
    public static func stands(_ history: PluginHistory?, readOf: String?, copyOf source: String, head: String) -> Bool {
        guard let history, readOf == source else { return false }
        return history.headCommit == head
    }

    /// Whether `line` may be installed over the copy of `source` now.
    public static func installs(_ line: PluginHistory.Line, from history: PluginHistory?, readOf: String?,
                                copyOf source: String) -> Bool {
        guard let history, readOf == source else { return false }
        return history.lines.contains(line)
    }
}

// MARK: - When each source is read

/// When each source of one's own is read — the official source's rules
/// (`CatalogueSchedule`), each source by its own state: a few seconds after
/// launch unless read in the last day, then daily on the minute's clock, a
/// failure again after an hour, and when Settings → Plugins is opened with
/// its list more than an hour old — whatever **Official catalogue** says.
/// One read at a time, the official source first, then each source as
/// `sources.json` lists them.
public enum SourceSchedule {
    /// The sources read at launch, in order.
    public static func atLaunch(_ sources: [OwnSource], states: [String: CatalogueState], now: Date) -> [String] {
        sources.map(\.id).filter { CatalogueSchedule.refreshesAtLaunch(states[$0] ?? CatalogueState(), now: now) }
    }

    /// The sources due on this minute's tick, in order: due by the schedule,
    /// not being read, and not tried in the last minute.
    public static func due(_ sources: [OwnSource], states: [String: CatalogueState], reading: Set<String>,
                           now: Date) -> [String] {
        sources.map(\.id).filter { id in
            let state = states[id] ?? CatalogueState()
            return !reading.contains(id) && CatalogueSchedule.nextDue(state, now: now) <= now
                && (state.lastAttempt.map { now.timeIntervalSince($0) > 60 } ?? true)
        }
    }

    /// The sources read when Settings → Plugins is opened, in order.
    public static func whenSettingsOpen(_ sources: [OwnSource], states: [String: CatalogueState], now: Date) -> [String] {
        sources.map(\.id).filter { CatalogueSchedule.refreshesWhenSettingsOpen(states[$0] ?? CatalogueState(), now: now) }
    }
}

// MARK: - What a read that did not finish says

/// Why a source's list is not fresh, in the operator's words (S4-20): the
/// official catalogue's sentences as they always were, naming GitHub; a
/// source of one's own's naming its host and its address — its `404` as one
/// that may be private (item 1), a GitLab's limit as the GitLab's (item 9:
/// anonymous gitlab.com's with what a token would change), and every other
/// reason with the host it is about (items 10 to 12). `readAt` is when the
/// list below was read, already formatted, or nil when there is no list;
/// `provider` the host's, `github` or `gitlab`. Read without a token: tokens
/// come with R3.
public enum CatalogueTrouble {
    public static func phrase(_ error: CatalogueError, address: String, host: String?, readAt: String?,
                              until: (Date) -> String, provider: String = SourceLink.github) -> Phrase {
        let host = host ?? "GitHub"
        switch error {
        case .rateLimited(let date) where provider == SourceLink.gitlab:
            return .sourceGitLabLimited(host: host, readAt: readAt, until: until(date),
                                        anonymousGitLabCom: host == SourceLink.gitLabCom)
        case .rateLimited(let date): return .catalogueLimited(readAt: readAt, until: until(date))
        case .rawRateLimited(let date): return .catalogueRawLimited(until: until(date))
        case .unreachable(let reason): return .catalogueUnreachable(reason: reason, readAt: readAt, host: host)
        case .notFound: return host == "GitHub" ? .catalogueNotFound(source: address) : .sourceNotFound(address: address)
        case .notARepository(let branch): return .catalogueNotARepository(source: address, branch: branch)
        case .futureFormat(let declared): return .catalogueFutureFormat(declared: declared)
        case .invalidPassport(let reason): return .catalogueInvalidPassport(source: address, reason: reason)
        case .refused(let status): return .catalogueRefused(status: status, host: host)
        case .badAnswer(let reason): return .catalogueBadAnswer(reason: reason, host: host)
        case .arrivedDifferent(let path, let expected, let got):
            return .catalogueArrivedDifferent(path: path, expected: expected, got: got)
        case .officialRepositoryChanged: return .catalogueOfficialRepositoryChanged
        }
    }
}

// MARK: - A test build

/// The line a test build carries under **Your sources** (S4-20, item 24): each
/// host it reads from somewhere else than the shipped build does — GitHub's
/// API or raw host pointed elsewhere (`UDeckPluginsAPIBase`,
/// `UDeckPluginsRawBase`), each host `UDeckPluginsHostMap` names — so that a
/// map put into an installed build is seen. Nothing for a build as shipped.
public enum TestBuild {
    public static func notices(infoDictionary info: [String: Any]?) -> [Phrase] {
        let read = GitHubEndpoints.from(infoDictionary: info)
        var said: [Phrase] = []
        if read.apiBase != GitHubEndpoints.official.apiBase {
            said.append(.sourcesTestBuild(host: GitHubEndpoints.official.apiBase.host ?? "api.github.com",
                                          base: read.apiBase.absoluteString))
        }
        if read.rawBase != GitHubEndpoints.official.rawBase {
            said.append(.sourcesTestBuild(host: GitHubEndpoints.official.rawBase.host ?? "raw.githubusercontent.com",
                                          base: read.rawBase.absoluteString))
        }
        if let map = info?["UDeckPluginsHostMap"] as? [String: Any] {
            for host in map.keys.sorted() {
                said.append(.sourcesTestBuild(host: host, base: (map[host] as? String) ?? "\(map[host] ?? "")"))
            }
        }
        return said
    }
}
