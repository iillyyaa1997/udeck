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

/// What uDeck asks of a repository host. GitHub implements it now; GitLab's
/// client implements the same questions in stage 4, through its own API.
public protocol RepositoryProvider: Sendable {
    var address: RepositoryAddress { get }

    /// The repository's default branch.
    func defaultBranch() async throws -> String
    /// The commit `branch` points at, unless it is still `etag`.
    func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer
    /// A tree object: the whole repository at a commit when `recursive`, one
    /// folder otherwise.
    func tree(_ sha: String, recursive: Bool) async throws -> GitTree
    /// One file at one commit, from the raw file host — never by branch name.
    func file(at path: String, commit: String) async throws -> Data
    /// The commits on `branch` that changed `path`, newest first.
    func commits(touching path: String, on branch: String) async throws -> [CommitSummary]

    /// Where a person reads a folder at a commit, in the browser.
    func folderPage(_ path: String, commit: String) -> URL?
    /// Where a person reads what changed between two commits.
    func comparePage(from: String, to: String) -> URL?
}

/// The rate-limit state every request of one source reads and updates.
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

    public init(apiBase: URL, rawBase: URL, repository: String) {
        self.apiBase = apiBase
        self.rawBase = rawBase
        self.repository = repository
    }

    public static let official = GitHubEndpoints(
        apiBase: URL(string: "https://api.github.com")!,
        rawBase: URL(string: "https://raw.githubusercontent.com")!,
        repository: RepositoryAddress.official.path
    )

    /// From an `Info.plist`, each key falling back to the shipped value when it
    /// is absent or not a URL.
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
            repository: repository
        )
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
    public let endpoints: GitHubEndpoints
    public let address: RepositoryAddress
    private let session: URLSession
    private let userAgent: String
    private let limits: RateLimitRecorder
    private let now: @Sendable () -> Date

    public static let requestTimeout: TimeInterval = 30

    public init(
        endpoints: GitHubEndpoints,
        udeckVersion: String,
        limits: RateLimitRecorder,
        session: URLSession = GitHubClient.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoints = endpoints
        self.address = RepositoryAddress(provider: "github", host: "github.com", path: endpoints.repository)
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

    private var repositoryPath: String { "repos/\(endpoints.repository)" }

    // MARK: - The questions

    public func defaultBranch() async throws -> String {
        let (data, _) = try await api(repositoryPath)
        struct Repository: Decodable { var default_branch: String }
        guard let answer = try? JSONDecoder().decode(Repository.self, from: data),
              !answer.default_branch.isEmpty else {
            throw ProviderError.badAnswer("the repository's description has no default branch")
        }
        return answer.default_branch
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

    public func folderPage(_ path: String, commit: String) -> URL? {
        URL(string: "https://\(address.host)/\(endpoints.repository)/tree/\(commit)/\(path)")
    }

    public func comparePage(from: String, to: String) -> URL? {
        URL(string: "https://\(address.host)/\(endpoints.repository)/compare/\(from)...\(to)")
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
