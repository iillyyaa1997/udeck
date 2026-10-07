#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Where a uDeck release's assets are: GitHub's releases of
/// `iillyyaa1997/udeck`, unless `UDECK_PLUGIN_DOWNLOAD_BASE` names another
/// place laid out the same way — `<base>/v<version>/<asset>` — such as a
/// mirror for runners that cannot reach GitHub. The variable says where; what
/// is there is judged by the files themselves, and once pinned, by the lock
/// file's sums.
public struct ReleaseSource: Equatable, Sendable {
    public static let variable = "UDECK_PLUGIN_DOWNLOAD_BASE"
    public static let github = "https://github.com/iillyyaa1997/udeck/releases/download"

    /// The base, without a `/` at its end.
    public let base: String

    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The source `environment` names: `UDECK_PLUGIN_DOWNLOAD_BASE`, or
    /// GitHub when it is unset or empty — as a CI variable left blank reads.
    public init(environment: [String: String]) throws {
        try self.init(base: environment[Self.variable].flatMap { $0.isEmpty ? nil : $0 } ?? Self.github)
    }

    /// `https://` or `file://`, and nothing a path appended to it would not
    /// mean: no query, no fragment, no space. Not `http://`: `pin` writes the
    /// sums it reads, and over plain HTTP anybody on the way could choose them.
    public init(base given: String) throws {
        let name = Self.variable
        if given.utf8.starts(with: "http://".utf8) {
            throw Problem(description: "\(name) is \(given): over plain http anybody on the way could choose the sums "
                          + "pin writes into the lock file — use https://")
        }
        let scheme = ["https://", "file://"].first { given.utf8.starts(with: $0.utf8) }
        guard let scheme else {
            throw Problem(description: "\(name) is \(given): an https:// or a file:// address, the folder that "
                          + "holds a folder v<version>/ for each release")
        }
        guard !given.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) else {
            throw Problem(description: "\(name) is \(given): an address with no space, query or fragment, "
                          + "since a release's folder and a file name are put after it")
        }
        var base = given
        if base.utf8.last == UInt8(ascii: "/") { base = String(decoding: base.utf8.dropLast(), as: UTF8.self) }
        guard base.utf8.count > scheme.utf8.count else {
            throw Problem(description: "\(name) is \(given), which names no place")
        }
        self.base = base
    }

    public var scheme: String { base.utf8.starts(with: "file://".utf8) ? "file" : "https" }

    /// The address of `asset` of release `version`.
    public func url(_ asset: String, of version: SemanticVersion) -> String {
        "\(base)/v\(version)/\(asset)"
    }

    /// The address of `asset` of the latest release, where the base is laid
    /// out as GitHub's — `…/releases/download`, beside `…/releases/latest/download`,
    /// which GitHub answers with the latest release's asset. Nil for a base
    /// that is not: a mirror has no "latest" of its own to ask.
    public func latest(_ asset: String) -> String? {
        let suffix = "/download"
        guard base.utf8.count > suffix.utf8.count, base.utf8.reversed().starts(with: suffix.utf8.reversed()) else { return nil }
        let releases = String(decoding: base.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
        return "\(releases)/latest/download/\(asset)"
    }

    /// The release an address of this source names — `<base>/vX.Y.Z/…` — as
    /// GitHub's latest is redirected to the release it is.
    public func version(in url: String) -> SemanticVersion? {
        let prefix = Array("\(base)/v".utf8)
        let bytes = Array(url.utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let rest = bytes.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else { return nil }
        return SemanticVersion(String(decoding: rest[rest.startIndex ..< slash], as: UTF8.self))
    }
}

/// What asking for a file came to.
public enum Fetched: Equatable, Sendable {
    case found([UInt8])
    /// Not there — a server's 404 or 410, or no such file — `at` the address
    /// asked last, after every redirect.
    case missing(at: String)
}

/// How `pin` reads a release: through curl in earnest, through a fake in
/// tests, which go on no network.
public protocol ReleaseFetching: Sendable {
    /// `url`'s file, or that it is not there; throws when it could not tell.
    func fetch(_ url: String) throws -> Fetched
}

/// Why a file could not be fetched — anything but found or missing.
public struct FetchFailure: Error, Equatable, CustomStringConvertible {
    public var description: String
}

/// The files of a release fetched with the system's curl, started as
/// `/usr/bin/env curl` on the `PATH` it is given.
///
/// Curl rather than Foundation's URLSession: URLSession is in
/// FoundationNetworking, the half of Foundation the static Linux binary leaves
/// out — with it would come all of Foundation and libcurl itself, linked into
/// every copy, and no proof here that the Static Linux SDK links them at all.
/// Curl is on every Mac, every GitHub runner, and in the image; its proxy
/// variables are the ones every CI knows, read as curl's manual says: `https_proxy`
/// or `HTTPS_PROXY`, else `all_proxy` or `ALL_PROXY`, and `no_proxy` or
/// `NO_PROXY` for the hosts reached without one. `pin` asks for nothing over
/// plain HTTP, so `http_proxy` (which curl reads in lowercase only) never
/// applies. The environment is handed to curl as it is, and nothing else of
/// the machine's: `-q` keeps curl from reading a `.curlrc`.
public struct Curl: ReleaseFetching {
    /// The largest file `pin` reads: the two it reads are a few hundred bytes.
    public static let largest = 1_048_576

    public let environment: [String: String]
    /// Where the folder of each file is made: the command's own
    /// (`ScratchFolder.home`), or a test's.
    let scratch: URL?

    public init(environment: [String: String]) {
        self.init(environment: environment, scratch: nil)
    }

    init(environment: [String: String], scratch: URL?) {
        self.environment = environment
        self.scratch = scratch
    }

    /// What curl is started with, for `url`, writing the file to `output`:
    /// redirects followed only to https, at most 10 of them; three tries on
    /// what curl calls transient (a timeout, a 5xx, a 429); the status and the
    /// address asked last printed after the transfer, whatever it came to.
    public static func arguments(for url: String, output: String) -> [String] {
        let scheme = url.utf8.starts(with: "file://".utf8) ? "file" : "https"
        return ["curl", "-q", "--silent", "--show-error", "--location", "--max-redirs", "10",
                "--proto", "=\(scheme)", "--proto-redir", "=https",
                "--connect-timeout", "30", "--max-time", "120", "--retry", "3",
                "--max-filesize", "\(largest)", "--output", output,
                "--write-out", "%{http_code}\\n%{url_effective}\\n", url]
    }

    public func fetch(_ url: String) throws -> Fetched {
        let folder = try ScratchFolder.make(ScratchFolder.pinPrefix, in: scratch ?? ScratchFolder.home)
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = folder.appendingPathComponent("body").path
        let ran = try Subprocess.run(Self.arguments(for: url, output: body), environment: environment, in: folder.path)
        let file = (try? Data(contentsOf: URL(fileURLWithPath: body))).map { [UInt8]($0) }
        return try Self.answer(status: ran.status, said: ran.output, errors: ran.errors, file: file, url: url)
    }

    /// What curl's run comes to: its exit status, what it printed after the
    /// transfer (`--write-out`), what it said on standard error, and the file
    /// it wrote, if any.
    static func answer(status: Int32, said: [UInt8], errors: [UInt8], file: [UInt8]?, url: String) throws -> Fetched {
        let why = Blank.trimmed(String(decoding: errors, as: UTF8.self))
        switch status {
        case 0:
            break
        case 37:
            // FILE couldn't read file: a file:// address with nothing there.
            return .missing(at: url)
        case 63:
            throw FetchFailure(description: "\(url) is larger than the \(largest) bytes pin reads")
        case 127:
            throw FetchFailure(description: "pin reads a release with curl, and there is no curl on the PATH")
        case -1:
            throw FetchFailure(description: "curl was stopped by a signal while it read \(url)")
        default:
            throw FetchFailure(description: "could not read \(url): curl exited \(status)\(why.isEmpty ? "" : ": \(why)")")
        }
        let lines = said.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard lines.count >= 2 else {
            throw FetchFailure(description: "could not read \(url): curl said \(PluginLock.shown(said))")
        }
        let code = String(decoding: lines[0], as: UTF8.self)
        let last = String(decoding: lines[1], as: UTF8.self)
        let local = url.utf8.starts(with: "file://".utf8)
        if (local && code == "000") || (!local && code == "200") {
            guard let file else { throw FetchFailure(description: "could not read \(url): curl wrote no file") }
            guard file.count <= largest else {
                throw FetchFailure(description: "\(url) is larger than the \(largest) bytes pin reads")
            }
            return .found(file)
        }
        if code == "404" || code == "410" { return .missing(at: last.isEmpty ? url : last) }
        throw FetchFailure(description: "could not read \(url): HTTP \(code) from \(last.isEmpty ? url : last)")
    }
}

/// The lock file a release makes, read from its source.
public enum ReleasePin {
    /// Which release.
    public enum Wanted: Equatable, Sendable {
        case latest
        case version(SemanticVersion)
    }

    /// The last uDeck release made before `udeck-plugin` was published with
    /// them: it and those before it have neither file.
    public static let lastWithout = SemanticVersion(major: 0, minor: 5, patch: 0)

    public struct Pinned: Equatable, Sendable {
        public var lock: PluginLock
        /// The image the digest is of, as the release names it.
        public var image: String
        /// The release's folder the files came from.
        public var from: String
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The lock file for `wanted`, from `source`, read with `fetching`.
    ///
    /// The latest release is asked for its image file at GitHub's latest
    /// address, which says the version; its `SHA256SUMS` is then read from that
    /// version's own folder, and the two must agree — so a release published
    /// between the two requests is a refusal, never a lock of two releases.
    /// Where the latest has no image file, GitHub's redirect still says which
    /// release it is, and the refusal names it.
    public static func pin(_ wanted: Wanted, from source: ReleaseSource, fetching: any ReleaseFetching) throws -> Pinned {
        let version: SemanticVersion
        var image: [UInt8]?
        switch wanted {
        case .latest:
            guard let latest = source.latest(ReleaseFiles.image) else {
                throw Failure(description: "\(ReleaseSource.variable) is \(source.base), which is not laid out as "
                              + "GitHub's releases (…/releases/download): it has no latest release to ask for — "
                              + "say which with --version X.Y.Z")
            }
            switch try fetch(latest, with: fetching) {
            case .found(let bytes):
                version = try failing { try ReleaseFiles.image(bytes).version }
                image = bytes
            case .missing(let at):
                if let named = source.version(in: at) { throw missing([ReleaseFiles.image], of: named, at: source) }
                throw Failure(description: "the latest release at \(source.base) has no \(ReleaseFiles.image) "
                              + "(\(at) is not there): \(firstWith)")
            }
        case .version(let asked):
            version = asked
        }
        var sums: [UInt8]?
        var gone: [String] = []
        switch try fetch(source.url(ReleaseFiles.sums, of: version), with: fetching) {
        case .found(let bytes): sums = bytes
        case .missing: gone.append(ReleaseFiles.sums)
        }
        if image == nil {
            switch try fetch(source.url(ReleaseFiles.image, of: version), with: fetching) {
            case .found(let bytes): image = bytes
            case .missing: gone.append(ReleaseFiles.image)
            }
        }
        guard let sums, let image, gone.isEmpty else { throw missing(gone, of: version, at: source) }
        let made = try failing { try ReleaseFiles.lock(sums: sums, image: image, version: version) }
        return Pinned(lock: made.lock, image: made.image.repository, from: "\(source.base)/v\(version)/")
    }

    static let firstWith = "udeck-plugin is published with uDeck's releases from the one after \(lastWithout) on — "
        + "pin one of those, with --version X.Y.Z"

    /// That release `version` has none of `assets` — and, for one up to
    /// 0.5.0, that it never could.
    static func missing(_ assets: [String], of version: SemanticVersion, at source: ReleaseSource) -> Failure {
        let what = assets.joined(separator: " and no ")
        let why = version <= lastWithout
            ? "uDeck \(lastWithout) and the releases before it were made before udeck-plugin was published with them; "
                + firstWith
            : "either there is no such release there, or it was made without udeck-plugin's assets: \(firstWith)"
        return Failure(description: "release v\(version) has no \(what) at \(source.base)/v\(version)/: \(why)")
    }

    static func fetch(_ url: String, with fetching: any ReleaseFetching) throws -> Fetched {
        do {
            return try fetching.fetch(url)
        } catch let failure as FetchFailure {
            throw Failure(description: failure.description)
        }
    }

    static func failing<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let problem as ReleaseFiles.Problem {
            throw Failure(description: problem.description)
        }
    }
}
