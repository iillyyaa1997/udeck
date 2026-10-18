import Foundation

/// Why a provider could not answer.
public enum ProviderError: Error, Equatable, Sendable {
    /// The API is not to be asked before this: the hourly limit is used up, or
    /// the host asked for a pause. Thrown without a request having been sent
    /// when the block was already known.
    case rateLimited(until: Date)
    /// The raw file host answered `429`; no raw request before this.
    case rawRateLimited(until: Date)
    /// `404`: the repository, the branch or the file is not there — or the
    /// repository is private, which GitHub answers the same way.
    case notFound
    /// Any other answer that is not a success, a `403` that is not a limit
    /// included, reported as the refusal it is.
    case refused(status: Int)
    /// No answer at all: no network, a name that does not resolve, a timeout.
    case unreachable(String)
    /// An answer, but not one that could be read.
    case badAnswer(String)
}

/// The head of a branch, asked conditionally.
public enum HeadAnswer: Equatable, Sendable {
    /// `304 Not Modified`: the branch points where it pointed last time.
    case unchanged
    /// The commit it points at now, and the `ETag` to ask with next time.
    case commit(String, etag: String?)
}

/// One commit that changed a path, newest first, as a folder's history lists it.
public struct CommitSummary: Codable, Equatable, Sendable {
    public var sha: String
    public var date: Date?

    public init(sha: String, date: Date?) {
        self.sha = sha
        self.date = date
    }
}

/// One pull request, as uDeck reads it: where its head is, and whether it
/// was merged or closed. The fork it came from and its title are for showing
/// only — a fork can be deleted, and its pull request's head is still read
/// through the repository it was opened against, by commit.
public struct PullRequest: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open
        case closed
    }

    public var number: Int
    public var state: State
    public var merged: Bool
    /// The commit it was merged as, on the branch it was merged into — only
    /// when it was merged: the host's word for an open pull request is a
    /// test merge, which no branch has.
    public var mergeCommit: String?
    /// The commit its head is at.
    public var head: String
    /// The head's branch, in the repository it came from.
    public var headRef: String
    /// That repository, `owner/repo` — nil when it was deleted.
    public var headRepository: String?
    public var title: String
    /// The branch it was opened against, and merged into when it was merged
    /// — nil when the host did not say. Only a merge into the default branch
    /// is what was verified (`Adoption`).
    public var base: String?

    public init(number: Int, state: State, merged: Bool, mergeCommit: String?, head: String, headRef: String,
                headRepository: String?, title: String, base: String? = nil) {
        self.number = number
        self.state = state
        self.merged = merged
        self.mergeCommit = mergeCommit
        self.head = head
        self.headRef = headRef
        self.headRepository = headRepository
        self.title = title
        self.base = base
    }

    /// GitHub's answer to `GET /repos/{o}/{r}/pulls/{n}`, or nil when it is
    /// not one: a number other than the one asked for, a head that is not a
    /// commit id, a state that is neither open nor closed.
    static func read(_ data: Data, asked number: Int) -> PullRequest? {
        struct Repository: Decodable { var full_name: String? }
        struct Head: Decodable { var sha: String; var ref: String?; var repo: Repository? }
        struct Base: Decodable { var ref: String? }
        struct Answer: Decodable {
            var number: Int
            var state: String
            var merged: Bool?
            var merge_commit_sha: String?
            var title: String?
            var head: Head
            var base: Base?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.number == number,
              let state = State(rawValue: answer.state), GitHash.isObjectID(answer.head.sha) else { return nil }
        let merged = answer.merged ?? false
        let mergeCommit = merged ? answer.merge_commit_sha.flatMap { GitHash.isObjectID($0) ? $0 : nil } : nil
        return PullRequest(number: number, state: state, merged: merged, mergeCommit: mergeCommit,
                           head: answer.head.sha, headRef: answer.head.ref ?? "",
                           headRepository: answer.head.repo?.full_name, title: answer.title ?? "",
                           base: answer.base?.ref.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Two commits compared, as `GET /repos/{o}/{r}/compare/{base}...{head}`
/// says it: whether `head` continues `base` — is ahead of it — or `base`
/// continues `head`, is the same commit, or neither does: the two have gone
/// different ways from a commit both have. All uDeck reads of the answer;
/// the commits and files GitHub lists with it are left unread.
public struct Comparison: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// `head` continues `base`: `base` is in its history.
        case ahead
        /// `base` continues `head`: `head` is in its history, and behind it.
        case behind
        /// The same commit.
        case identical
        /// Neither is in the other's history.
        case diverged
    }

    public var status: Status
    /// Commits `head` has that `base` does not.
    public var aheadBy: Int
    /// Commits `base` has that `head` does not.
    public var behindBy: Int

    public init(status: Status, aheadBy: Int, behindBy: Int) {
        self.status = status
        self.aheadBy = aheadBy
        self.behindBy = behindBy
    }

    /// GitHub's answer, or nil when it is not one: a status it does not
    /// have, a count that is not a number.
    static func read(_ data: Data) -> Comparison? {
        struct Answer: Decodable {
            var status: String
            var ahead_by: Int
            var behind_by: Int
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let status = Status(rawValue: answer.status), answer.ahead_by >= 0, answer.behind_by >= 0 else { return nil }
        return Comparison(status: status, aheadBy: answer.ahead_by, behindBy: answer.behind_by)
    }
}

/// A repository as its host describes it, `GET /repos/{o}/{r}`: its name, its
/// default branch, and whether it is a fork — and, of a fork, the repository
/// its network grew from (`source`) and the one it was forked from
/// (`parent`), `owner/repo` each, as GitHub names them (fields **measured**
/// when stage 3 was designed: `AmanShaikhTech10/Hello-World` answers `fork`
/// true and `octocat/Hello-World` as both).
public struct RepositoryDescription: Equatable, Sendable {
    /// `owner/repo` as the host spells it now — nil when it did not say.
    public var fullName: String?
    public var defaultBranch: String
    public var fork: Bool
    /// The root of a fork's network: the repository every fork in it was
    /// made from, however many forks deep.
    public var source: String?
    /// The repository it was forked from.
    public var parent: String?
    /// The number the host knows the repository by, which neither a rename
    /// nor a transfer changes — `1393324153` for the official repository
    /// (**measured**, 2026-10-18); nil when the answer did not say one, or
    /// said one that is not a whole number above 0.
    public var id: Int?

    public init(fullName: String?, defaultBranch: String, fork: Bool, source: String? = nil, parent: String? = nil,
                id: Int? = nil) {
        self.fullName = fullName
        self.defaultBranch = defaultBranch
        self.fork = fork
        self.source = source
        self.parent = parent
        self.id = id
    }

    /// Whether this is a fork of `official` — directly, or a fork of a fork:
    /// a fork whose network's root is it, `owner/repo` compared whatever its
    /// case, as GitHub compares it. Not the official repository itself, not
    /// a repository of its own, and not a fork of anything else.
    public func isFork(of official: RepositoryAddress) -> Bool {
        guard fork, let source else { return false }
        return source.lowercased() == official.path.lowercased()
    }

    /// GitHub's answer, or nil when it is not one: no default branch, or a
    /// `fork` that is not a yes or a no.
    static func read(_ data: Data) -> RepositoryDescription? {
        struct Named: Decodable { var full_name: String? }
        struct Answer: Decodable {
            var full_name: String?
            var default_branch: String
            var fork: Bool?
            var source: Named?
            var parent: Named?
        }
        // Apart, so that an id that is not a number costs the id, not the answer.
        struct Numbered: Decodable { var id: Int? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), !answer.default_branch.isEmpty else {
            return nil
        }
        let id = (try? JSONDecoder().decode(Numbered.self, from: data))?.id.flatMap { $0 > 0 ? $0 : nil }
        return RepositoryDescription(fullName: answer.full_name, defaultBranch: answer.default_branch,
                                     fork: answer.fork ?? false, source: answer.source?.full_name,
                                     parent: answer.parent?.full_name, id: id)
    }
}

/// What uDeck asks of a repository host. GitHub implements it now; GitLab's
/// client implements the same questions in stage 4, through its own API.
public protocol RepositoryProvider: Sendable {
    var address: RepositoryAddress { get }

    /// The repository's default branch.
    func defaultBranch() async throws -> String
    /// The repository as the host describes it — its default branch, and
    /// whether it is a fork, and of which.
    func describe() async throws -> RepositoryDescription
    /// The commit `branch` points at, unless it is still `etag`.
    func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer
    /// A tree object: the whole repository at a commit when `recursive`, one
    /// folder otherwise.
    func tree(_ sha: String, recursive: Bool) async throws -> GitTree
    /// One file at one commit, from the raw file host — never by branch name.
    func file(at path: String, commit: String) async throws -> Data
    /// The commits on `branch` that changed `path`, newest first.
    func commits(touching path: String, on branch: String) async throws -> [CommitSummary]
    /// Pull request `number`: its head, and whether it was merged or closed.
    func pull(_ number: Int) async throws -> PullRequest
    /// Whether `head` continues `base` (`Comparison`) — `notFound` when
    /// either commit is not there, as after a push that rewrote history and
    /// a clean-up that took the old commits away.
    func compare(_ base: String, _ head: String) async throws -> Comparison

    /// Where a person reads a folder at a commit, in the browser.
    func folderPage(_ path: String, commit: String) -> URL?
    /// Where a person reads what changed between two commits.
    func comparePage(from: String, to: String) -> URL?

    /// The same host's provider for `repository` — this one, for its own —
    /// asking the same API and raw host, and counted against the same limit:
    /// what a branch of a fork is read through. Nil for a repository on
    /// another host, or one its host could not name.
    func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)?
}

extension RepositoryProvider {
    /// One file of `repository` at `commit`, from its raw host — through this
    /// provider when that is its repository, through the same host's provider
    /// for it otherwise (`provider(for:)`), and never from another host:
    /// what the installer fetches a copy's files with, from the repository
    /// its request names (`InstallRequest.repository`).
    public func file(of repository: RepositoryAddress, at path: String, commit: String) async throws -> Data {
        guard let line = provider(for: repository) else { throw ProviderError.notFound }
        return try await line.file(at: path, commit: commit)
    }
}

/// The rate-limit state every request of one source reads and updates — its
/// own repository's and its forks' alike, since the host counts what an
/// address asks, whichever repository it asks about
/// (`GitHubClient.client(for:)`).
///
/// A class behind a lock rather than a value, because a refresh and an install
/// can overlap — an install needs only raw files and may run while the API is
/// blocked — and both have to see the same block the moment either learns of
/// it.
public final class RateLimitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var state: RateLimitState

    public init(_ state: RateLimitState = RateLimitState()) {
        self.state = state
    }

    public var current: RateLimitState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func update<T>(_ body: (inout RateLimitState) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
}

/// Where a GitHub source is: its API, its raw file host, and `owner/repo`.
///
/// Read from `Info.plist` (`UDeckPluginsAPIBase`, `UDeckPluginsRawBase`,
/// `UDeckPluginsRepository`) so that the lab's build can point at the fake
/// repository in its guest, the way it is pointed at its own update feed.
public struct GitHubEndpoints: Equatable, Sendable {
    public var apiBase: URL
    public var rawBase: URL
    /// `owner/repo`.
    public var repository: String
    /// The number GitHub knows the official repository by
    /// (`UDeckPluginsRepositoryID`), which its daily describe has to answer
    /// (`OfficialRepositoryCheck`): nil when the build carries none, and then
    /// nothing is compared.
    public var repositoryID: Int?

    public init(apiBase: URL, rawBase: URL, repository: String, repositoryID: Int? = nil) {
        self.apiBase = apiBase
        self.rawBase = rawBase
        self.repository = repository
        self.repositoryID = repositoryID
    }

    /// `iillyyaa1997/udeck-plugins`'s number, as `GET /repositories/1393324153`
    /// answers it (**measured**, 2026-10-18).
    public static let officialRepositoryID = 1_393_324_153

    public static let official = GitHubEndpoints(
        apiBase: URL(string: "https://api.github.com")!,
        rawBase: URL(string: "https://raw.githubusercontent.com")!,
        repository: RepositoryAddress.official.path,
        repositoryID: officialRepositoryID
    )

    /// From an `Info.plist`, each key falling back to the shipped value when it
    /// is absent or not a URL — the repository's number to the shipped one when
    /// it is absent, and to none when it is there and is not a whole number
    /// above 0.
    public static func from(infoDictionary info: [String: Any]?) -> GitHubEndpoints {
        func url(_ key: String, _ fallback: URL) -> URL {
            guard let text = info?[key] as? String, let url = URL(string: text),
                  url.scheme == "https" || url.scheme == "http" else { return fallback }
            return url
        }
        var repository = official.repository
        if let text = info?["UDeckPluginsRepository"] as? String,
           text.split(separator: "/").count == 2 {
            repository = text
        }
        return GitHubEndpoints(
            apiBase: url("UDeckPluginsAPIBase", official.apiBase),
            rawBase: url("UDeckPluginsRawBase", official.rawBase),
            repository: repository,
            repositoryID: info?["UDeckPluginsRepositoryID"].map(Self.number) ?? official.repositoryID
        )
    }

    /// A plist's number — an integer, or digits written as a string — when
    /// it is a whole number above 0.
    static func number(_ value: Any) -> Int? {
        let number: Int?
        switch value {
        case let value as Int: number = value
        case let value as String: number = value.allSatisfy({ ("0" ... "9").contains($0) }) ? Int(value) : nil
        default: number = nil
        }
        return number.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// GitHub, read anonymously through its REST API and its raw file host.
///
/// The transport is a parameter — a `URLSession` — so tests answer it with
/// recorded responses through a stub `URLProtocol` and never reach the
/// network. Every request carries `User-Agent: uDeck/<version>` (GitHub
/// refuses requests without one); API requests also carry
/// `Accept: application/vnd.github+json`, except the conditional head, and
/// `X-GitHub-Api-Version: 2022-11-28`. Nothing carries a token or a cookie,
/// and each request gives up after 30 seconds.
public struct GitHubClient: RepositoryProvider {
    public private(set) var endpoints: GitHubEndpoints
    public private(set) var address: RepositoryAddress
    /// How the API's requests name the repository (`Addressing`).
    public private(set) var addressing: Addressing
    private let session: URLSession
    private let userAgent: String
    private let limits: RateLimitRecorder
    private let now: @Sendable () -> Date

    public static let requestTimeout: TimeInterval = 30

    /// How the API's requests name the repository: by its path,
    /// `/repos/{owner}/{repo}/…` — the official repository, as in stage 3,
    /// and its forks — or by the number GitHub knows it by,
    /// `/repositories/{id}/…`: a source of one's own after it was looked up
    /// (stage 4), which a repository made later at its old name can never
    /// answer for. Raw files come by its path at a commit either way, and
    /// each is hashed against a listing asked by the same addressing.
    public enum Addressing: Equatable, Sendable {
        case path
        case id(Int)
    }

    public init(
        endpoints: GitHubEndpoints,
        udeckVersion: String,
        limits: RateLimitRecorder,
        session: URLSession = GitHubClient.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() },
        addressing: Addressing = .path
    ) {
        self.endpoints = endpoints
        self.address = RepositoryAddress(provider: "github", host: "github.com", path: endpoints.repository)
        self.addressing = addressing
        self.session = session
        self.userAgent = "uDeck/\(udeckVersion)"
        self.limits = limits
        self.now = now
    }

    /// A session that keeps nothing: no cookies, no cache that could answer a
    /// conditional request on GitHub's behalf, no credentials.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    private var repositoryPath: String {
        switch addressing {
        case .path: "repos/\(endpoints.repository)"
        case .id(let id): "repositories/\(id)"
        }
    }

    // MARK: - The questions

    public func defaultBranch() async throws -> String {
        try await describe().defaultBranch
    }

    /// `GET /repos/{o}/{r}` — one request, which says the default branch and
    /// whether it is a fork, and of which, together.
    public func describe() async throws -> RepositoryDescription {
        let (data, _) = try await api(repositoryPath)
        guard let description = RepositoryDescription.read(data) else {
            throw ProviderError.badAnswer("the repository's description has no default branch")
        }
        return description
    }

    public func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer {
        var headers = ["Accept": "application/vnd.github.sha"]
        if let etag { headers["If-None-Match"] = etag }
        let (data, response) = try await api("\(repositoryPath)/commits/\(Self.escape(branch))",
                                             headers: headers, allowNotModified: true)
        if response.statusCode == 304 { return .unchanged }
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHash.isObjectID(sha) else {
            throw ProviderError.badAnswer("the head of \(branch) is not a commit id: \(sha.prefix(60))")
        }
        return .commit(sha, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func tree(_ sha: String, recursive: Bool) async throws -> GitTree {
        let (data, _) = try await api("\(repositoryPath)/git/trees/\(sha)",
                                      query: recursive ? [URLQueryItem(name: "recursive", value: "1")] : [])
        do {
            return try JSONDecoder().decode(GitTree.self, from: data)
        } catch {
            throw ProviderError.badAnswer("the listing of \(sha.prefix(7)) could not be read: \(error)")
        }
    }

    public func file(at path: String, commit: String) async throws -> Data {
        if let until = limits.current.rawBlocked(now: now()) { throw ProviderError.rawRateLimited(until: until) }
        let url = Self.appending(endpoints.rawBase, "\(endpoints.repository)/\(commit)/\(path)")
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await send(request)
        if let until = limits.update({ $0.observeRaw(status: response.statusCode, now: now()) }) {
            throw ProviderError.rawRateLimited(until: until)
        }
        switch response.statusCode {
        case 200: return data
        case 404: throw ProviderError.notFound
        default: throw ProviderError.refused(status: response.statusCode)
        }
    }

    public func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
        let (data, _) = try await api("\(repositoryPath)/commits", query: [
            URLQueryItem(name: "sha", value: branch),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "per_page", value: "100"),
        ])
        struct Person: Decodable { var date: String? }
        struct Inner: Decodable { var committer: Person?; var author: Person? }
        struct Commit: Decodable { var sha: String; var commit: Inner? }
        guard let commits = try? JSONDecoder().decode([Commit].self, from: data) else {
            throw ProviderError.badAnswer("the history of \(path) could not be read")
        }
        let dates = ISO8601DateFormatter()
        return commits.filter { GitHash.isObjectID($0.sha) }.map { commit in
            let text = commit.commit?.committer?.date ?? commit.commit?.author?.date
            return CommitSummary(sha: commit.sha, date: text.flatMap { dates.date(from: $0) })
        }
    }

    /// `GET /repos/{o}/{r}/pulls/{n}` — one request, which says the head,
    /// the state and the merge together; a pull request that is not there
    /// is `notFound`.
    public func pull(_ number: Int) async throws -> PullRequest {
        let (data, _) = try await api("\(repositoryPath)/pulls/\(number)")
        guard let pull = PullRequest.read(data, asked: number) else {
            throw ProviderError.badAnswer("pull request #\(number) could not be read")
        }
        return pull
    }

    /// `GET /repos/{o}/{r}/compare/{base}...{head}?per_page=1` — one request.
    /// GitHub lists the files that differ with every answer, however many
    /// commits are asked for (161 053 bytes for one squash merge of the
    /// official repository, measured when stage 3 was designed); one commit
    /// asked for keeps the rest of it short. A commit that is not there is
    /// `notFound`.
    public func compare(_ base: String, _ head: String) async throws -> Comparison {
        guard GitHash.isObjectID(base), GitHash.isObjectID(head) else {
            throw ProviderError.badAnswer("only two commits are compared, not \(base.prefix(40)) and \(head.prefix(40))")
        }
        let (data, _) = try await api("\(repositoryPath)/compare/\(base)...\(head)",
                                      query: [URLQueryItem(name: "per_page", value: "1")])
        guard let comparison = Comparison.read(data) else {
            throw ProviderError.badAnswer("the comparison of \(base.prefix(7)) with \(head.prefix(7)) could not be read")
        }
        return comparison
    }

    public func folderPage(_ path: String, commit: String) -> URL? {
        URL(string: "https://\(address.host)/\(endpoints.repository)/tree/\(commit)/\(path)")
    }

    public func comparePage(from: String, to: String) -> URL? {
        URL(string: "https://\(address.host)/\(endpoints.repository)/compare/\(from)...\(to)")
    }

    public func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? {
        client(for: repository)
    }

    /// This client for another repository on the same host: the same API and
    /// raw host, the same session, and the same limit (`RateLimitRecorder`) —
    /// GitHub counts what an address asks, whichever repository it asks
    /// about, so a fork's answers spend what the official repository's do,
    /// and a limit either learns of stops both. Nil for another host or
    /// provider, and for a path that is not GitHub's `owner/repo`
    /// (`RepositoryLink.isOwner`, `isRepository`): nothing else goes into a
    /// request's path. A client addressed by id is itself for its own
    /// repository, whatever the case of its name, and nil for any other path —
    /// an earlier spelling of its own name among them: what a path names now
    /// may be another repository, and a source's requests never go by a name
    /// (`Addressing`). A copy of a source is read through that source's
    /// client, found by the record's `source`, not by its `repository`.
    public func client(for repository: RepositoryAddress) -> GitHubClient? {
        guard repository.provider == address.provider, repository.host == address.host else { return nil }
        let parts = repository.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, RepositoryLink.isOwner(parts[0]), RepositoryLink.isRepository(parts[1]) else { return nil }
        if case .id = addressing { return repository.path.lowercased() == address.path.lowercased() ? self : nil }
        var client = self
        client.endpoints.repository = repository.path
        client.address = RepositoryAddress(provider: address.provider, host: address.host, path: repository.path)
        return client
    }

    /// This client, addressed by id, for its own repository under the name its
    /// host gives it now — `path`, as a describe by its number answered it: the
    /// same number for every API request, and `path` for its raw files and its
    /// pages. Nil for a client addressed by path, whose name is all it has,
    /// and for a path that is not GitHub's `owner/repo`.
    public func renamed(to path: String) -> GitHubClient? {
        guard case .id = addressing else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, RepositoryLink.isOwner(parts[0]), RepositoryLink.isRepository(parts[1]) else { return nil }
        var client = self
        client.endpoints.repository = path
        client.address = RepositoryAddress(provider: address.provider, host: address.host, path: path)
        return client
    }

    // MARK: - Asking

    private func api(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        allowNotModified: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        if let until = limits.current.apiBlocked(now: now()) { throw ProviderError.rateLimited(until: until) }
        var components = URLComponents(url: Self.appending(endpoints.apiBase, path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw ProviderError.badAnswer("no address for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await send(request)
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let verdict = limits.update { $0.observeAPI(status: response.statusCode, headers: fields, now: now()) }
        switch (response.statusCode, verdict) {
        case (_, .limited(let until)): throw ProviderError.rateLimited(until: until)
        case (200 ..< 300, _): return (data, response)
        case (304, _) where allowNotModified: return (data, response)
        case (404, _), (422, _): throw ProviderError.notFound
        default: throw ProviderError.refused(status: response.statusCode)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.badAnswer("not an HTTP answer")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable(error.localizedDescription)
        }
    }

    /// `base` with `path` after it, keeping whatever path the base already has
    /// — the lab's fake sits under `/api` and `/raw` on one port.
    static func appending(_ base: URL, _ path: String) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/" + path) ?? base
    }

    /// A branch name as one path segment.
    static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? segment
    }
}
