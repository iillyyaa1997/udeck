import Foundation

// GitLab — gitlab.com, or one's own — read anonymously through its API, v4
// (stage 4, S4-14): the same questions GitHub's client answers
// (`RepositoryProvider`), for a project of one's own added as a source. Every
// endpoint here was measured anonymously on gitlab.com, and read-only on a
// self-hosted 18.8.2, when stage 4 was designed. See docs/plugin-repository.md,
// "GitLab".

/// Where a GitLab is: its API, `https://<host>/api/v4`, and its pages,
/// `https://<host>` — or, in a test build, its API wherever
/// `UDeckPluginsHostMap` sends that host (`HostMap`). The pages a person opens
/// keep the real host whatever the map says.
public struct GitLabEndpoints: Equatable, Sendable {
    /// As a source names it: lowercased, with a port when it has one.
    public var host: String
    public var apiBase: URL
    public var webBase: URL

    public init(host: String, apiBase: URL, webBase: URL) {
        self.host = host
        self.apiBase = apiBase
        self.webBase = webBase
    }

    /// `host`'s endpoints: its own, or its API at `hostMap`'s base for it —
    /// nil for a host that is not one an address could name.
    public static func of(_ host: String, hostMap: [String: URL] = [:]) -> GitLabEndpoints? {
        guard let web = URL(string: "https://\(host)"), web.host != nil else { return nil }
        let base = hostMap[host] ?? web
        return GitLabEndpoints(host: host, apiBase: GitHubClient.appending(base, "api/v4"), webBase: web)
    }
}

/// `UDeckPluginsHostMap` (S4-21): the hosts a test build reads from somewhere
/// else than they are — `{"gitlab.example.test": "http://127.0.0.1:8768"}` —
/// each to a base of `http` or `https`. A build as shipped carries none, and
/// the lab refuses one that does (`builds._verify`); a build that carries one
/// says so under **Your sources** (`TestBuild`). Only what is sent changes:
/// where a token goes is held by the address it was checked against, and the
/// pages a person opens keep the real host.
public enum HostMap {
    public static let key = "UDeckPluginsHostMap"

    public static func from(infoDictionary info: [String: Any]?) -> [String: URL] {
        guard let map = info?[key] as? [String: Any] else { return [:] }
        var read: [String: URL] = [:]
        for (host, value) in map {
            guard let text = value as? String, let url = URL(string: text), url.host != nil,
                  url.scheme == "https" || url.scheme == "http" else { continue }
            read[host.lowercased()] = url
        }
        return read
    }
}

extension RepositoryAddress {
    /// Whether this host's listings give a file's size: GitLab's do not
    /// (`RepositoryRules.listingRefusals`), so its plugins are held to rule 8
    /// as their files arrive, and a row says how many files and not how many
    /// bytes.
    public var listsSizes: Bool { provider != SourceLink.gitlab }

    /// The host, as a button names it: *Open on GitHub*, or *Open on
    /// gitlab.example*.
    public var hostName: String { host == SourceLink.githubHost ? "GitHub" : host }
}

/// What **Look up** of a GitLab project by its path comes to.
public enum GitLabProjectLookUp: Equatable, Sendable {
    /// The project: its number, its path as GitLab spells it, its default branch.
    case found(RepositoryDescription)
    /// GitLab's own `404`: no such project — or a private one; or a project
    /// whose repository it does not let be read anonymously — empty, or its
    /// code for members only — and so names no default branch.
    case notFound
    /// An answer that is not GitLab's: a `404` whose body is not GitLab's
    /// JSON, or a success that is no project — *"… did not answer as GitLab"*.
    case notGitLab
}

/// A GitLab project, read anonymously through the API, addressed by its number.
///
/// Like `GitHubClient`: the transport is a `URLSession` — a session that keeps
/// nothing, 30 seconds a request — so tests answer it through a stub
/// `URLProtocol`; every request carries `User-Agent: uDeck/<version>` and
/// `Accept: application/json`, and every answer is read for the limit
/// (`RateLimitRecorder`, the source's own). After **Look up** a project is
/// always asked for as `/projects/<id>`: a project made later at its path
/// never answers for it. Files come from the API too — GitLab has no raw host
/// to read anonymously by commit — by path at a commit, each hashed against
/// the listing by the caller.
public struct GitLabClient: RepositoryProvider {
    public private(set) var endpoints: GitLabEndpoints
    public private(set) var address: RepositoryAddress
    /// The number GitLab knows the project by.
    public let remoteID: Int
    private let session: URLSession
    private let userAgent: String
    private let limits: RateLimitRecorder
    private let now: @Sendable () -> Date

    /// The most pages a listing is followed across: a hundred entries each,
    /// past what any plugin repository holds.
    public static let mostPages = 100

    public init(
        endpoints: GitLabEndpoints,
        path: String,
        remoteID: Int,
        udeckVersion: String,
        limits: RateLimitRecorder,
        session: URLSession = GitHubClient.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoints = endpoints
        self.address = RepositoryAddress(provider: SourceLink.gitlab, host: endpoints.host, path: path)
        self.remoteID = remoteID
        self.session = session
        self.userAgent = "uDeck/\(udeckVersion)"
        self.limits = limits
        self.now = now
    }

    private var project: String { "projects/\(remoteID)" }

    // MARK: - Look up

    /// **Look up**: the project at `path` — the one request ever addressed by
    /// its path, URL-encoded with its `/` as `%2F` — through `endpoints`.
    public static func lookUp(_ path: String, endpoints: GitLabEndpoints, udeckVersion: String,
                              limits: RateLimitRecorder, session: URLSession = GitHubClient.makeSession(),
                              now: @escaping @Sendable () -> Date = { Date() }) async throws -> GitLabProjectLookUp {
        let asking = GitLabClient(endpoints: endpoints, path: path, remoteID: 0, udeckVersion: udeckVersion,
                                  limits: limits, session: session, now: now)
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await asking.api("projects/\(escape(path))", lookingUp: true)
        } catch GitLabAnswer.notGitLab {
            return .notGitLab
        } catch ProviderError.notFound {
            return .notFound
        }
        guard let description = Self.description(answer.0), description.id != nil else {
            return Self.isProject(answer.0) ? .notFound : .notGitLab
        }
        return .found(description)
    }

    // MARK: - The questions

    public func defaultBranch() async throws -> String {
        try await describe().defaultBranch
    }

    /// `GET /projects/:id` — its default branch, its path as GitLab spells
    /// it now, and the project it was forked from, when the answer says one
    /// (anonymous gitlab.com answers leave `forked_from_project` out). Only
    /// an answer naming the project's own number is believed: one naming
    /// another, or none — a redirect's, something that is no GitLab — never
    /// renames the source.
    public func describe() async throws -> RepositoryDescription {
        let (data, _) = try await api(project)
        guard let description = Self.description(data) else {
            throw ProviderError.badAnswer("the project's description has no default branch")
        }
        guard let id = description.id else {
            throw ProviderError.badAnswer("the project asked for as \(remoteID) answered with no number")
        }
        guard id == remoteID else {
            throw ProviderError.badAnswer("the project asked for as \(remoteID) answered as \(id)")
        }
        return description
    }

    /// `GET /projects/:id/repository/branches/:branch`, its name escaped
    /// whole — `/` too — with `If-None-Match`: GitLab answers a weak `ETag`
    /// and `304` to that exact value (**measured**).
    public func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        let (data, response) = try await api("\(project)/repository/branches/\(Self.escape(branch))", headers: headers,
                                             allowNotModified: true)
        if response.statusCode == 304 { return .unchanged }
        struct Commit: Decodable { var id: String }
        struct Branch: Decodable { var commit: Commit }
        guard let answer = try? JSONDecoder().decode(Branch.self, from: data), GitHash.isObjectID(answer.commit.id) else {
            throw ProviderError.badAnswer("the head of \(branch) is not a commit id")
        }
        return .commit(answer.commit.id, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    /// Every path a catalogue needs at `commit`: the root — `GET
    /// /repository/tree?ref=` — and, only when it has a `plugins` folder,
    /// everything under it — `…&path=plugins&recursive=true` — each followed
    /// across its pages (`x-next-page`), a hundred to a page. Put together
    /// as one listing of the whole repository, never truncated: each
    /// entry's `id` is git's (**measured**), its path the whole path, and no
    /// entry has a size. A root with no `plugins` is a repository that offers
    /// no plugins yet, and the second listing is never asked for — GitLab
    /// answers it `404 invalid revision or path Not Found` (**measured**).
    /// Not recursive, the root alone.
    public func tree(_ sha: String, recursive: Bool) async throws -> GitTree {
        let root = try await listing(ref: sha, path: nil)
        guard recursive, root.contains(where: { $0.path == CommitListing.pluginsFolder && $0.type == "tree" }) else {
            return GitTree(sha: sha, tree: root.map(\.entry), truncated: false)
        }
        let plugins = try await listing(ref: sha, path: CommitListing.pluginsFolder)
        return GitTree(sha: sha, tree: (root + plugins).map(\.entry), truncated: false)
    }

    /// `GET /repository/files/:path/raw?ref=:commit` — one file at one commit.
    /// Refused before it is read when GitLab says it is larger than a
    /// plugin's file may be (`X-Gitlab-Size`, or `Content-Length`), and read
    /// no further than one byte past that otherwise (`ProviderError.tooLarge`).
    public func file(at path: String, commit: String) async throws -> Data {
        try await bytes("\(project)/repository/files/\(Self.escape(path))/raw",
                        query: [URLQueryItem(name: "ref", value: commit)],
                        most: RepositoryRules.maximumFileBytes)
    }

    /// `GET /repository/commits?ref_name=&path=` — the commits on `branch`
    /// that changed `path`, newest first, a hundred at most.
    public func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
        let (data, _) = try await api("\(project)/repository/commits", query: [
            URLQueryItem(name: "ref_name", value: branch),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "per_page", value: "100"),
        ])
        struct Commit: Decodable { var id: String; var committed_date: String? }
        guard let commits = try? JSONDecoder().decode([Commit].self, from: data) else {
            throw ProviderError.badAnswer("the history of \(path) could not be read")
        }
        return commits.filter { GitHash.isObjectID($0.id) }.map { CommitSummary(sha: $0.id, date: $0.committed_date.flatMap(Self.date)) }
    }

    /// `GET /merge_requests/:iid` — a merge request, as a pull request reads:
    /// `opened` is open; `closed` and `locked` closed; `merged` closed and
    /// merged, as `merge_commit_sha` — or `squash_commit_sha` when GitLab
    /// names no merge commit. Not asked in stage 4: a source's merge requests
    /// are not installed from yet.
    public func pull(_ number: Int) async throws -> PullRequest {
        let (data, _) = try await api("\(project)/merge_requests/\(number)")
        guard let pull = Self.mergeRequest(data, asked: number) else {
            throw ProviderError.badAnswer("merge request !\(number) could not be read")
        }
        return pull
    }

    /// `GET /repository/merge_base?refs[]=&refs[]=` — the newest commit both
    /// have, which says how the two stand: the same commit is identical; a
    /// base that is it is what `head` continues; a head that is it is behind;
    /// anything else diverged. GitLab counts no commits here, so both counts
    /// are 0. A commit that is not there is `notFound` — GitLab answers it
    /// `400 Could not find ref`. Not asked in stage 4.
    public func compare(_ base: String, _ head: String) async throws -> Comparison {
        guard GitHash.isObjectID(base), GitHash.isObjectID(head) else {
            throw ProviderError.badAnswer("only two commits are compared, not \(base.prefix(40)) and \(head.prefix(40))")
        }
        if base == head { return Comparison(status: .identical, aheadBy: 0, behindBy: 0) }
        let (data, _) = try await api("\(project)/repository/merge_base", query: [
            URLQueryItem(name: "refs[]", value: base), URLQueryItem(name: "refs[]", value: head),
        ], notFoundOn400: { body in String(decoding: body, as: UTF8.self).contains("Could not find ref") })
        struct Answer: Decodable { var id: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), GitHash.isObjectID(answer.id) else {
            throw ProviderError.badAnswer("the merge base of \(base.prefix(7)) and \(head.prefix(7)) could not be read")
        }
        switch answer.id {
        case base: return Comparison(status: .ahead, aheadBy: 0, behindBy: 0)
        case head: return Comparison(status: .behind, aheadBy: 0, behindBy: 0)
        default: return Comparison(status: .diverged, aheadBy: 0, behindBy: 0)
        }
    }

    public func folderPage(_ path: String, commit: String) -> URL? {
        URL(string: "\(webAddress)/-/tree/\(commit)/\(path)")
    }

    public func comparePage(from: String, to: String) -> URL? {
        URL(string: "\(webAddress)/-/compare/\(from)...\(to)")
    }

    /// The project's page, on its real host whatever a host map says.
    private var webAddress: String {
        var text = endpoints.webBase.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return "\(text)/\(address.path)"
    }

    /// Itself, for its own project — its path byte for byte, as GitLab names
    /// paths — and nothing for any other: no other project's files under its
    /// number.
    public func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? {
        repository == address ? self : nil
    }

    /// This client under the path GitLab gives the project now — the same
    /// number for every request, and `path` for its pages. Nil for a path
    /// that is no project's (`SourceLink.isGitLabSegment`).
    public func renamed(to path: String) -> GitLabClient? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2 ... 20).contains(segments.count), segments.allSatisfy(SourceLink.isGitLabSegment) else { return nil }
        var client = self
        client.address = RepositoryAddress(provider: address.provider, host: address.host, path: path)
        return client
    }

    // MARK: - Reading answers

    /// A project's description as GitLab answers it, or nil without a default
    /// branch: `id`, `path_with_namespace`, `default_branch`, and
    /// `forked_from_project` when it is there.
    static func description(_ data: Data) -> RepositoryDescription? {
        struct Parent: Decodable { var path_with_namespace: String? }
        struct Answer: Decodable {
            var path_with_namespace: String?
            var default_branch: String?
            var forked_from_project: Parent?
        }
        struct Numbered: Decodable { var id: Int? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), let branch = answer.default_branch,
              !branch.isEmpty else { return nil }
        let id = (try? JSONDecoder().decode(Numbered.self, from: data))?.id.flatMap { $0 > 0 ? $0 : nil }
        return RepositoryDescription(fullName: answer.path_with_namespace, defaultBranch: branch,
                                     fork: answer.forked_from_project != nil,
                                     parent: answer.forked_from_project?.path_with_namespace, id: id)
    }

    /// Whether an answer is a project, default branch or not: its number and
    /// its path, as GitLab names every project it answers.
    static func isProject(_ data: Data) -> Bool {
        struct Answer: Decodable { var id: Int; var path_with_namespace: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return false }
        return answer.id > 0 && !answer.path_with_namespace.isEmpty
    }

    /// A merge request as GitLab answers it, or nil when it is not one.
    static func mergeRequest(_ data: Data, asked number: Int) -> PullRequest? {
        struct Answer: Decodable {
            var iid: Int
            var state: String
            var title: String?
            var sha: String?
            var merge_commit_sha: String?
            var squash_commit_sha: String?
            var source_branch: String?
            var target_branch: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.iid == number,
              let head = answer.sha, GitHash.isObjectID(head) else { return nil }
        let state: PullRequest.State
        let merged: Bool
        switch answer.state {
        case "opened": (state, merged) = (.open, false)
        case "closed", "locked": (state, merged) = (.closed, false)
        case "merged": (state, merged) = (.closed, true)
        default: return nil
        }
        let commit = [answer.merge_commit_sha, answer.squash_commit_sha].compactMap { $0 }.first(where: GitHash.isObjectID)
        return PullRequest(number: number, state: state, merged: merged, mergeCommit: merged ? commit : nil, head: head,
                           headRef: answer.source_branch ?? "", headRepository: nil, title: answer.title ?? "",
                           base: answer.target_branch.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// One entry of a tree answer: `id`, `type`, `path` and `mode`.
    struct Entry: Decodable {
        var id: String
        var type: String
        var path: String
        var mode: String

        var entry: GitTree.Entry { GitTree.Entry(path: path, mode: mode, type: type, sha: id, size: nil) }
    }

    /// Every entry of a tree listing at `ref`, `path` recursively when given,
    /// page after page.
    private func listing(ref: String, path: String?) async throws -> [Entry] {
        var entries: [Entry] = []
        var page = 1
        for _ in 0 ..< Self.mostPages {
            var query = [URLQueryItem(name: "ref", value: ref)]
            if let path {
                query += [URLQueryItem(name: "path", value: path), URLQueryItem(name: "recursive", value: "true")]
            }
            query += [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            let (data, response) = try await api("\(project)/repository/tree", query: query)
            guard let found = try? JSONDecoder().decode([Entry].self, from: data) else {
                throw ProviderError.badAnswer("the listing of \(ref.prefix(7)) could not be read")
            }
            entries += found
            let next = response.value(forHTTPHeaderField: "x-next-page")?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !next.isEmpty else { return entries }
            guard let number = Int(next), number > page else {
                throw ProviderError.badAnswer("the listing of \(ref.prefix(7)) names \(next.prefix(20)) as its next page")
            }
            page = number
        }
        throw ProviderError.badAnswer("the listing of \(ref.prefix(7)) goes on past \(Self.mostPages) pages")
    }

    // MARK: - Asking

    /// An answer that was a `404` and not GitLab's: only **Look up** asks for it.
    private enum GitLabAnswer: Error { case notGitLab }

    private func request(_ path: String, query: [URLQueryItem], headers: [String: String]) throws -> URLRequest {
        if let until = limits.current.apiBlocked(now: now()) { throw ProviderError.rateLimited(until: until) }
        var components = URLComponents(url: GitHubClient.appending(endpoints.apiBase, path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw ProviderError.badAnswer("no address for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: GitHubClient.requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func api(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        allowNotModified: Bool = false,
        notFoundOn400: (Data) -> Bool = { _ in false },
        lookingUp: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try request(path, query: query, headers: headers)
        let (data, response): (Data, HTTPURLResponse)
        do {
            let (got, answer) = try await session.data(for: request)
            guard let http = answer as? HTTPURLResponse else { throw ProviderError.badAnswer("not an HTTP answer") }
            (data, response) = (got, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable(error.localizedDescription)
        }
        if lookingUp, response.statusCode == 404, !Self.isGitLabError(data) { throw GitLabAnswer.notGitLab }
        try judge(response, body: data, allowNotModified: allowNotModified, notFoundOn400: notFoundOn400)
        return (data, response)
    }

    /// One file, read as it arrives, no further than one byte past `most`.
    private func bytes(_ path: String, query: [URLQueryItem], most: Int) async throws -> Data {
        let request = try request(path, query: query, headers: [:])
        let stream: URLSession.AsyncBytes
        let response: HTTPURLResponse
        do {
            let (got, answer) = try await session.bytes(for: request)
            guard let http = answer as? HTTPURLResponse else { throw ProviderError.badAnswer("not an HTTP answer") }
            (stream, response) = (got, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable(error.localizedDescription)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            // A refusal's body is GitLab's few words: read whole, and judged.
            var body = Data()
            do {
                for try await byte in stream {
                    body.append(byte)
                    if body.count > 64 * 1024 { break }
                }
            } catch {
                throw ProviderError.unreachable(error.localizedDescription)
            }
            try judge(response, body: body, allowNotModified: false, notFoundOn400: { _ in true })
            throw ProviderError.refused(status: response.statusCode)
        }
        try judge(response, body: Data(), allowNotModified: false, notFoundOn400: { _ in true })
        let said = ["X-Gitlab-Size", "Content-Length"].compactMap { response.value(forHTTPHeaderField: $0) }
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.max()
        if let said, said > most {
            stream.task.cancel()
            throw ProviderError.tooLarge(bytes: said)
        }
        var data = Data()
        data.reserveCapacity(min(said ?? 0, most + 1))
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count > most {
                    stream.task.cancel()
                    throw ProviderError.tooLarge(bytes: data.count)
                }
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable(error.localizedDescription)
        }
        return data
    }

    /// What an answer's status says (S4-14): a success, and a `304` only where
    /// it is asked for; `404` not found, and a `400` only where the endpoint
    /// answers a missing ref or file so — any other `400` is a refusal, so a
    /// request uDeck got wrong never reads as *"… or it is private"*; `401` a
    /// token wanted or not taken; a `403` naming `insufficient_scope` the
    /// scope wanted; other `403`s and `429`s by the limit (`RateLimitState`);
    /// a `3xx` that came back a move; anything else a refusal. A request
    /// without a token follows a redirect, as uDeck's session always has
    /// (S4-19), so only a `3xx` with nowhere to go comes back today; what a
    /// redirect answered is held to the project's number (`describe`) and
    /// its files to the listing's hashes.
    private func judge(_ response: HTTPURLResponse, body: Data, allowNotModified: Bool,
                       notFoundOn400: (Data) -> Bool) throws {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let status = response.statusCode
        let verdict = limits.update { $0.observeAPI(status: status, headers: fields, now: now()) }
        if status == 403, let wanted = Self.insufficientScope(body) {
            throw ProviderError.forbidden(scope: wanted.isEmpty ? nil : wanted)
        }
        switch (status, verdict) {
        case (_, .limited(let until)): throw ProviderError.rateLimited(until: until)
        case (200 ..< 300, _): return
        case (304, _) where allowNotModified: return
        case (404, _): throw ProviderError.notFound
        case (400, _) where notFoundOn400(body): throw ProviderError.notFound
        case (401, _): throw ProviderError.unauthorized
        case (300 ..< 400, _): throw ProviderError.moved(status: status)
        default: throw ProviderError.refused(status: status)
        }
    }

    /// Whether a body is GitLab's own error: a JSON object with its `message`
    /// or `error` — `{"message":"404 Project Not Found"}`.
    static func isGitLabError(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["message"] is String || object["message"] is [String: Any] || object["error"] is String
    }

    /// The scope a `403` says the token lacks, when it says
    /// `insufficient_scope` — `""` when it names none; nil for any other `403`.
    static func insufficientScope(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["error"] as? String == "insufficient_scope" else { return nil }
        return object["scope"] as? String ?? ""
    }

    /// A segment of a path, everything but GitLab's unreserved characters
    /// escaped: `group/project` is `group%2Fproject`.
    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// GitLab's dates: `2026-10-16T10:11:42.000-05:00`, with or without the fraction.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
