import Foundation

/// A github.com link pasted into **Install from a link…**, read as what it
/// names — before anything is asked of GitHub (`RefResolver` asks).
///
/// The forms read, with or without `https://` and `www.`, a query and a
/// fragment ignored:
///
/// * `github.com/<official>/pull/<n>` — and any page under it, `…/files`,
///   `…/commits` — a pull request of the official repository;
/// * `github.com/<owner>/<repo>/tree/<branch>`, and any folder under it: the
///   branch is everything up to the last `plugins/<id>` — and the plugin is
///   that `<id>` — or, without one, everything after `tree/`, so a branch
///   called `feature/uptime` reads as itself;
/// * `github.com/<owner>/<repo>` — a repository's own page, which stands for
///   its default branch.
///
/// The official repository's default branch is its catalogue, which only
/// GitHub can say (`RefResolver`). Every other repository is read as one that
/// may be a fork of it, which GitHub is asked too. Everything else is refused
/// with what it is: a commit (stage 5), another host or another repository's
/// pull request — a source of its own (stage 4) — or a page that names no
/// branch and no pull request.
public enum RepositoryLink: Equatable, Sendable {
    /// The official repository's own page.
    case officialRepository
    /// A pull request of the official repository.
    case pullRequest(Int)
    /// A branch of the official repository, and the plugin whose folder the
    /// link went into, when it went into one.
    case branch(String, plugin: String?)
    /// A branch of another repository, which may be a fork of the official one.
    case forkBranch(RepositoryAddress, branch: String, plugin: String?)
    /// Another repository's own page: its default branch.
    case forkRepository(RepositoryAddress)

    /// Why a link is not read.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing was pasted.
        case empty
        /// Not a github.com link at all: no host, an address with a port or
        /// a name, `git@…`, no repository in it.
        case notALink
        /// A link to another host — a source of its own, which comes later.
        case notGitHub(host: String)
        /// A link to one commit: installing a commit comes later.
        case commit(String)
        /// A pull request of a repository other than the official one — a
        /// source of its own, which comes later.
        case otherRepositoryPullRequest(RepositoryAddress, Int)
        /// `tree/` followed by a name git does not allow for a branch.
        case notABranch(String)
        /// A page of a repository that names no branch and no pull request:
        /// its issues, its releases, a file.
        case unsupported(page: String)
    }

    /// What `text` names, `official` being the official repository.
    public static func read(_ text: String, official: RepositoryAddress) -> Result<RepositoryLink, Refusal> {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { return .failure(.empty) }
        for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest = rest.dropFirst(scheme.count)
        }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<slash].lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // `git@github.com:owner/repo`, `user@host`, `host:port`, a scheme
        // other than https: none of them is a page's address.
        guard !host.isEmpty, host.contains("."), !host.contains(where: { "@:".contains($0) }),
              !rest.contains("://") else { return .failure(.notALink) }
        guard host == "github.com" else { return .failure(.notGitHub(host: host)) }

        var segments: [String] = []
        for raw in rest[slash...].split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(raw).removingPercentEncoding, !segment.isEmpty else { return .failure(.notALink) }
            segments.append(segment)
        }
        guard segments.count >= 2 else { return .failure(.notALink) }
        var name = segments[1]
        if segments.count == 2, name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        guard isOwner(segments[0]), isRepository(name) else { return .failure(.notALink) }
        let address = RepositoryAddress(provider: official.provider, host: official.host, path: "\(segments[0])/\(name)")
        // GitHub's owners and repositories are one whatever their case.
        let isOfficial = address.path.lowercased() == official.path.lowercased()

        guard segments.count > 2 else { return .success(isOfficial ? .officialRepository : .forkRepository(address)) }
        let page = segments[2]
        let after = Array(segments.dropFirst(3))
        switch page {
        case "pull":
            guard let text = after.first, let number = pullRequestNumber(text) else {
                return .failure(.unsupported(page: page))
            }
            return isOfficial ? .success(.pullRequest(number)) : .failure(.otherRepositoryPullRequest(address, number))
        case "tree":
            guard !after.isEmpty else { return .failure(.unsupported(page: page)) }
            let (branch, plugin) = branchAndPlugin(after)
            // `tree/<commit>` is GitHub's *Browse files* at a commit: a
            // commit's link, not a branch's.
            if GitHash.isObjectID(branch) { return .failure(.commit(branch)) }
            guard isBranch(branch) else { return .failure(.notABranch(branch)) }
            return .success(isOfficial ? .branch(branch, plugin: plugin)
                                       : .forkBranch(address, branch: branch, plugin: plugin))
        case "commit":
            return .failure(.commit(after.first ?? ""))
        default:
            return .failure(.unsupported(page: page))
        }
    }

    /// The branch and the plugin in what follows `tree/`: split at the last
    /// `plugins/<id>` that leaves a branch before it, and otherwise the whole
    /// of it a branch — which is how a link into a plugin's folder on a
    /// branch whose name holds `/` is read. A link to the root of a branch
    /// called `x/plugins/uptime` reads as `uptime` on `x`: GitHub's own
    /// links cannot tell the two apart either.
    static func branchAndPlugin(_ segments: [String]) -> (branch: String, plugin: String?) {
        var index = segments.count - 2
        while index >= 1 {
            if segments[index] == CommitListing.pluginsFolder, PluginIdentifier(rawValue: segments[index + 1]) != nil {
                return (segments[..<index].joined(separator: "/"), segments[index + 1])
            }
            index -= 1
        }
        return (segments.joined(separator: "/"), nil)
    }

    /// A pull request's number: digits only, from 1.
    static func pullRequestNumber(_ text: String) -> Int? {
        guard (1 ... 9).contains(text.count), text.allSatisfy({ ("0" ... "9").contains($0) }),
              let number = Int(text), number > 0 else { return nil }
        return number
    }

    /// GitHub's rule for an owner: letters, digits and `-`, up to 39.
    static func isOwner(_ text: String) -> Bool {
        (1 ... 39).contains(text.count) && text.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
    }

    /// GitHub's rule for a repository's name: letters, digits, `.`, `_`, `-`,
    /// up to 100, and not `.` or `..`.
    static func isRepository(_ text: String) -> Bool {
        (1 ... 100).contains(text.count) && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }

    /// What git allows for a branch's name (`git check-ref-format --branch`):
    /// no part starting with `.` or ending in `.lock`, no `..`, no `@{`, no
    /// control character, space or any of `~^:?*[\`, not ending in `.`, not
    /// starting with `-`, and not `@` alone. It goes into a request's path
    /// and into `installed.json`, so what git would refuse is refused here.
    static func isBranch(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("-"), !name.hasSuffix("."), !name.hasSuffix("/"),
              !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F
            || " ~^:?*[\\".unicodeScalars.contains(scalar) {
            return false
        }
        return name.split(separator: "/").allSatisfy { part in !part.hasPrefix(".") && !part.hasSuffix(".lock") }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar)
    }
}
