import Foundation

/// The address of a source of one's own, pasted into **Add a source…** as a
/// browser shows it — read as the GitHub repository or the GitLab project it
/// names, before anything is asked of its host (stage 4).
///
/// What is read, with or without `https://`, a query and a fragment ignored:
///
/// * `github.com/<owner>/<repo>` — with or without `www.` — and any page under
///   it: `…/tree/<branch>`, `…/blob/…`, `…/pull/3` and the rest all come to the
///   repository, which is what a source is; `.git` after the name is dropped.
///   The names are GitHub's (`RepositoryLink.isOwner`, `isRepository`).
/// * Any other host is taken as GitLab — gitlab.com, `www.` or not, or one's
///   own, with a port if it has one (`:443`, HTTPS's own, is dropped): the
///   path before GitLab's separator `/-/`, `.git` dropped from its end, is the
///   project — 2 to 20 segments of letters, digits, `.`, `_` and `-`, none
///   starting with `-` or `.` — nested groups included.
///
/// Refused before any request, each refusal saying what to paste instead:
/// `http://` (sources are read over HTTPS only); `git@host:path` and `ssh://`;
/// a login inside the address; a github.com page that is not a repository —
/// settings, a gist, an owner's or an organisation's page; and the official
/// repository, which is the official catalogue.
public struct SourceLink: Equatable, Sendable {
    /// `github` or `gitlab`.
    public var provider: String
    /// Lowercased, with a port when it has one other than 443.
    public var host: String
    /// `owner/repo`, or `group/…/project`, as it was written.
    public var path: String

    public init(provider: String, host: String, path: String) {
        self.provider = provider
        self.host = host
        self.path = path
    }

    public static let github = "github"
    public static let gitlab = "gitlab"
    public static let githubHost = "github.com"
    /// GitLab's own host, whose anonymous limit is GitLab's smallest.
    public static let gitLabCom = "gitlab.com"

    /// The repository or the project, as a record and a sentence name it.
    public var address: RepositoryAddress { RepositoryAddress(provider: provider, host: host, path: path) }

    /// Its page — what **Add as a source…** fills the field with.
    public var page: String { "https://\(host)/\(path)" }

    /// Why an address is not read.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing was pasted.
        case empty
        /// No host, a host that is not a name, no repository or project in it.
        case notALink
        /// `http://`: sources are read over HTTPS only.
        case notHTTPS
        /// `git@host:path` or `ssh://`: git's address over SSH, not a page.
        case ssh
        /// A name, or a name and a password, before the host.
        case login
        /// A github.com page that names no repository — `page` is what it is:
        /// its first segment (`settings`, an owner), or the host (a gist's).
        case notARepository(page: String)
        /// The official repository: its plugins are the official catalogue.
        case officialCatalogue
        /// A GitLab path that is no project's: fewer than 2 segments, more
        /// than 20, or one out of rule.
        case notAProject
        /// An address written down — in `sources.json` — that reads as another
        /// one, `host/path`, than written (`refusal(of:official:)`); never
        /// what a pasted address comes to.
        case readsAsAnother(String)
    }

    /// What `text` names, `official` being the official repository.
    public static func read(_ text: String, official: RepositoryAddress) -> Result<SourceLink, Refusal> {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { return .failure(.empty) }
        if let separator = rest.range(of: "://") {
            switch rest[..<separator.lowerBound].lowercased() {
            case "https": rest = rest[separator.upperBound...]
            case "http": return .failure(.notHTTPS)
            case "ssh", "git+ssh", "ssh+git": return .failure(.ssh)
            default: return .failure(.notALink)
            }
        }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<slash]
        // `git@gitlab.com:group/project.git` — scp's form, which git reads as SSH.
        if authority.contains("@"), authority.contains(":"), !text.contains("://") { return .failure(.ssh) }
        guard !authority.contains("@") else { return .failure(.login) }
        guard let (name, port) = hostAndPort(authority.lowercased()) else { return .failure(.notALink) }

        var segments: [String] = []
        for raw in rest[slash...].split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(raw).removingPercentEncoding, !segment.isEmpty else { return .failure(.notALink) }
            segments.append(segment)
        }

        let github = name == githubHost || name == "www.\(githubHost)"
        if github {
            guard port == nil else { return .failure(.notALink) }
            return gitHub(segments, official: official)
        }
        // A gist, the API, the raw file host: GitHub's, and no repository's page.
        if name.hasSuffix(".\(githubHost)") || name == "githubusercontent.com" || name.hasSuffix(".githubusercontent.com") {
            return .failure(.notARepository(page: name))
        }
        let host = (name == "www.\(gitLabCom)" ? gitLabCom : name) + (port.map { ":\($0)" } ?? "")
        return gitLab(segments, host: host)
    }

    /// The host's name and its port — nil for one that is not a name: labels
    /// of letters, digits and `-`, none starting or ending with `-`, at least
    /// two; a port of 1 to 65535, and none for 443.
    static func hostAndPort(_ authority: String) -> (name: String, port: Int?)? {
        var name = authority
        var port: Int?
        if let colon = authority.lastIndex(of: ":") {
            let digits = authority[authority.index(after: colon)...]
            guard (1 ... 5).contains(digits.count), digits.allSatisfy({ ("0" ... "9").contains($0) }),
                  let number = Int(digits), (1 ... 65535).contains(number) else { return nil }
            name = String(authority[..<colon])
            port = number == 443 ? nil : number
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.count <= 253, labels.count >= 2, labels.allSatisfy({ label in
            (1 ... 63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
        }) else { return nil }
        return (name, port)
    }

    /// GitHub's pages that are not a repository's, by the first segment of
    /// their path: an owner can be called none of these.
    static let gitHubPages: Set<String> = [
        "about", "account", "apps", "codespaces", "collections", "contact", "copilot", "customer-stories", "dashboard",
        "enterprise", "events", "explore", "features", "issues", "join", "login", "logout", "marketplace", "new",
        "notifications", "organizations", "orgs", "pricing", "pulls", "readme", "search", "security", "sessions",
        "settings", "site", "sponsors", "stars", "topics", "trending", "users", "watching",
    ]

    private static func gitHub(_ segments: [String], official: RepositoryAddress) -> Result<SourceLink, Refusal> {
        guard let owner = segments.first else { return .failure(.notARepository(page: githubHost)) }
        if gitHubPages.contains(owner.lowercased()) { return .failure(.notARepository(page: owner)) }
        guard segments.count >= 2 else { return .failure(.notARepository(page: owner)) }
        var repository = segments[1]
        if repository.lowercased().hasSuffix(".git") { repository.removeLast(4) }
        guard RepositoryLink.isOwner(owner), RepositoryLink.isRepository(repository) else { return .failure(.notALink) }
        let path = "\(owner)/\(repository)"
        // GitHub's owners and repositories are one whatever their case.
        if official.provider == github, official.host == githubHost, official.path.lowercased() == path.lowercased() {
            return .failure(.officialCatalogue)
        }
        return .success(SourceLink(provider: github, host: githubHost, path: path))
    }

    private static func gitLab(_ segments: [String], host: String) -> Result<SourceLink, Refusal> {
        var project = Array(segments.prefix { $0 != "-" })
        if var last = project.last, last.lowercased().hasSuffix(".git") {
            last.removeLast(4)
            project[project.count - 1] = last
        }
        guard (2 ... 20).contains(project.count), project.allSatisfy(isGitLabSegment) else {
            return .failure(.notAProject)
        }
        return .success(SourceLink(provider: gitlab, host: host, path: project.joined(separator: "/")))
    }

    /// One segment of a GitLab project's path: letters, digits, `.`, `_` and
    /// `-`, not starting with `-` or `.`.
    static func isGitLabSegment(_ segment: String) -> Bool {
        guard let first = segment.unicodeScalars.first, first != "-", first != "." else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar)
                || "._-".unicodeScalars.contains(scalar)
        }
    }

    /// Whether `address` is one this reads back as itself — what a source in
    /// `sources.json` has to be: nil when it is, otherwise why not, or
    /// `readsAsAnother` when it reads as another provider, host or path than
    /// the one written (a GitLab project said to be on github.com, a path with
    /// a page of it after it).
    public static func refusal(of address: RepositoryAddress, official: RepositoryAddress) -> Refusal? {
        switch read("https://\(address.host)/\(address.path)", official: official) {
        case .failure(let refusal): return refusal
        case .success(let link): return link.address == address ? nil : .readsAsAnother(link.address.description)
        }
    }
}
