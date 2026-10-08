import Foundation
import Testing
@testable import UDeckPluginCommand
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// A release as `pin` reads it, served from memory: an address and its file,
/// and where an address is redirected — as GitHub sends `latest` to the
/// release it is. Nothing here goes on the network.
struct FakeRelease: ReleaseFetching {
    var files: [String: [UInt8]] = [:]
    var redirects: [String: String] = [:]
    /// Addresses that fail as a network that does not answer.
    var unreachable: Set<String> = []

    func fetch(_ url: String) throws -> Fetched {
        if unreachable.contains(url) { throw FetchFailure(description: "could not read \(url): curl exited 7: no route") }
        let target = redirects[url] ?? url
        if let bytes = files[target] { return .found(bytes) }
        return .missing(at: target)
    }

    static let base = ReleaseSource.github
    static let ghcr = "ghcr.io/iillyyaa1997/udeck-plugin"

    /// Release `version`, as make-cli.sh writes its two files, at `base`.
    static func release(_ version: String, base: String = base, image repository: String = ghcr,
                        digest: String = "sha256:" + String(repeating: "d", count: 64)) -> FakeRelease {
        var release = FakeRelease()
        release.add(version, base: base, image: repository, digest: digest)
        return release
    }

    mutating func add(_ version: String, base: String = base, image repository: String = ghcr,
                      digest: String = "sha256:" + String(repeating: "d", count: 64)) {
        let parsed = SemanticVersion(version)!
        let image = Array(ReleaseFiles.imageText(repository: repository, version: parsed, digest: digest).utf8)
        var sums = ""
        for platform in PluginLock.platforms {
            sums += "\(ReleaseFiles.sha256(Array("\(platform) \(version)".utf8)))  \(PluginLock.archive(platform, of: parsed))\n"
        }
        sums += "\(ReleaseFiles.sha256(image))  \(ReleaseFiles.image)\n"
        sums += "\(ReleaseFiles.sha256(Array("sources \(version)".utf8)))  \(ReleaseFiles.imageSources(of: parsed))\n"
        files["\(base)/v\(version)/\(ReleaseFiles.sums)"] = Array(sums.utf8)
        files["\(base)/v\(version)/\(ReleaseFiles.image)"] = image
    }

    /// GitHub's latest, sent to release `version`.
    mutating func latest(_ version: String, base: String = base) {
        let releases = String(base.dropLast("/download".count))
        redirects["\(releases)/latest/download/\(ReleaseFiles.image)"] = "\(base)/v\(version)/\(ReleaseFiles.image)"
        redirects["\(releases)/latest/download/\(ReleaseFiles.sums)"] = "\(base)/v\(version)/\(ReleaseFiles.sums)"
    }

    func sums(_ version: String, base: String = base) -> String {
        String(decoding: files["\(base)/v\(version)/\(ReleaseFiles.sums)"] ?? [], as: UTF8.self)
    }
}

/// A release's `SHA256SUMS` and image file, read as strictly as
/// Scripts/make-cli.sh reads the image file before a release names it.
@Suite("A release's files, as pin reads them")
struct ReleaseFilesTests {
    let digest = "sha256:" + String(repeating: "d", count: 64)
    let version = SemanticVersion(major: 0, minor: 6, patch: 0)

    func image(_ text: String) throws -> ReleaseFiles.Image { try ReleaseFiles.image(Array(text.utf8)) }

    @Test("the image file push writes is read: its image, its version, its digest")
    func imageFile() throws {
        let text = "image=ghcr.io/iillyyaa1997/udeck-plugin\ntag=v0.6.0\ndigest=\(digest)\nplatforms=linux/amd64,linux/arm64\n"
        #expect(ReleaseFiles.imageText(repository: FakeRelease.ghcr, version: version, digest: digest) == text)
        let read = try image(text)
        #expect(read == ReleaseFiles.Image(repository: FakeRelease.ghcr, version: version, digest: digest))
        // A mirror, or CI's own registry: any registry, the name udeck-plugin.
        #expect(try image(text.replacingOccurrences(of: "ghcr.io/iillyyaa1997", with: "localhost:5001/iillyyaa1997")).repository
                == "localhost:5001/iillyyaa1997/udeck-plugin")
    }

    /// The cases Scripts/make-cli.sh's own tests refuse, and the two its
    /// reading once let through (D1b's review): lines after the last, and no
    /// line break after it.
    @Test("an image file that is not what push writes is refused, and said why", arguments: [
        ("digest=sha256:short", "no line digest=sha256:<64 hexadecimal digits>"),
        ("digest=", "no line digest="),
        ("tag=v0.6.0\n", "no line tag=vX.Y.Z"),
        ("tag=v0.6", "no line tag=vX.Y.Z"),
        ("tag=0.6.0", "no line tag=vX.Y.Z"),
        ("tag=v00.6.0", "no line tag=vX.Y.Z"),
        ("image=", "no line image=<registry>/<path>/udeck-plugin"),
        ("image=ghcr.io/somebody/else", "no line image="),
        ("image=GHCR.IO/iillyyaa1997/udeck-plugin", "no line image="),
        ("image=ghcr.io//udeck-plugin", "no line image="),
        ("image=ghcr.io/iillyyaa1997/udeck-plugin@sha256:x", "no line image="),
        ("platforms=linux/amd64", "not what a release writes"),
        ("extra digest", "no line digest="),
        ("trailing line breaks", "not what a release writes"),
        ("no final line break", "not what a release writes"),
        ("CRLF", "no line tag=vX.Y.Z"),
        ("a byte order mark", "no line image="),
        ("a fifth line", "not what a release writes"),
    ])
    func imageRefused(_ change: String, _ said: String) {
        var text = "image=ghcr.io/iillyyaa1997/udeck-plugin\ntag=v0.6.0\ndigest=\(digest)\nplatforms=linux/amd64,linux/arm64\n"
        switch change {
        case "tag=v0.6.0\n": text = text.replacingOccurrences(of: change, with: "")
        case "extra digest": text += "digest=sha256:" + String(repeating: "c", count: 64) + "\n"
        case "trailing line breaks": text += "\n\n\n"
        case "no final line break": text.removeLast()
        case "CRLF": text = text.replacingOccurrences(of: "\n", with: "\r\n")
        case "a byte order mark": text = "\u{FEFF}" + text
        case "a fifth line": text += "source=https://example.com\n"
        default:
            let key = String(change.prefix { $0 != "=" })
            text = text.split(separator: "\n").map { $0.hasPrefix(key + "=") ? change : String($0) }.joined(separator: "\n") + "\n"
        }
        do {
            let read = try image(text)
            Issue.record("\(change): read as \(read)")
        } catch let problem as ReleaseFiles.Problem {
            #expect(problem.description.contains(said), "\(change): \(problem.description)")
        } catch {
            Issue.record("\(change): \(error)")
        }
    }

    func sums(_ lines: [String]) throws -> [String: String] {
        try ReleaseFiles.sums(Array(lines.map { $0 + "\n" }.joined().utf8), of: version)
    }

    var goodSums: [String] {
        PluginLock.platforms.enumerated().map { "\(String(repeating: "\($0.offset)", count: 64))  udeck-plugin-0.6.0-\($0.element).tar.gz" }
            + ["\(String(repeating: "9", count: 64))  udeck-plugin-image.txt",
               "\(String(repeating: "8", count: 64))  udeck-plugin-image-sources-0.6.0.tar"]
    }

    @Test("SHA256SUMS: a sum for each archive, the image file and the image's sources, as sha256sum writes it")
    func sumsRead() throws {
        let read = try sums(goodSums)
        #expect(read["udeck-plugin-0.6.0-linux-aarch64.tar.gz"] == String(repeating: "2", count: 64))
        #expect(read["udeck-plugin-image.txt"] == String(repeating: "9", count: 64))
        #expect(read["udeck-plugin-image-sources-0.6.0.tar"] == String(repeating: "8", count: 64))
        #expect(read.count == 5)
        #expect(try sums(goodSums.reversed()) == read, "in any order")
    }

    @Test("SHA256SUMS that names anything else, or the same file twice, is refused")
    func sumsRefused() {
        let cases: [([String], String)] = [
            (Array(goodSums.dropFirst()), "names no udeck-plugin-0.6.0-macos-universal.tar.gz"),
            (goodSums + ["\(String(repeating: "a", count: 64))  udeck-plugin-0.6.0-linux-riscv64.tar.gz"],
             "which udeck-plugin \(UDeckRelease.version) does not know"),
            (goodSums + [goodSums[0]], "names udeck-plugin-0.6.0-macos-universal.tar.gz twice"),
            (goodSums.map { $0.replacingOccurrences(of: "0.6.0", with: "0.5.9") }, "does not know"),
            ([goodSums[0].replacingOccurrences(of: "  ", with: " *")] + goodSums.dropFirst(), "is not <sha256>  <name>"),
            (["ABCDEF" + String(repeating: "0", count: 58) + "  udeck-plugin-0.6.0-macos-universal.tar.gz"] + goodSums.dropFirst(),
             "is not <sha256>  <name>"),
            ([String(goodSums[0].dropFirst())] + goodSums.dropFirst(), "is not <sha256>  <name>"),
            (goodSums + [""], "line 6, is not"),
            // The image's sources are part of every release from 0.6.0 on —
            // of its own version, and once.
            (goodSums.filter { !$0.hasSuffix(".tar") }, "names no udeck-plugin-image-sources-0.6.0.tar"),
            (goodSums.map { $0.replacingOccurrences(of: "sources-0.6.0", with: "sources-0.5.9") }, "does not know"),
            (goodSums + ["\(String(repeating: "7", count: 64))  udeck-plugin-image-sources-0.6.0.tar"],
             "names udeck-plugin-image-sources-0.6.0.tar twice"),
            (goodSums + ["\(String(repeating: "7", count: 64))  udeck-plugin-image-sources-0.6.0.tar.gz"], "does not know"),
        ]
        for (lines, said) in cases {
            #expect(throws: ReleaseFiles.Problem.self) { try sums(lines) }
            do { _ = try sums(lines) } catch { #expect("\(error)".contains(said), "\(lines): \(error)") }
        }
        #expect(throws: ReleaseFiles.Problem.self) {
            try ReleaseFiles.sums(Array(goodSums.joined(separator: "\n").utf8), of: version)
        }
    }

    @Test("the lock of a release is its archives' sums and its image's digest — once the two files agree")
    func lock() throws {
        let release = FakeRelease.release("0.6.0")
        let sums = try #require(release.files["\(FakeRelease.base)/v0.6.0/SHA256SUMS"])
        let image = try #require(release.files["\(FakeRelease.base)/v0.6.0/udeck-plugin-image.txt"])
        let made = try ReleaseFiles.lock(sums: sums, image: image, version: version)
        #expect(made.lock.version == version && made.lock.image == digest)
        #expect(made.lock.archives["linux-x86_64"] == ReleaseFiles.sha256(Array("linux-x86_64 0.6.0".utf8)))
        #expect(made.image.repository == FakeRelease.ghcr)

        // An image file the sums do not name: another release's, or changed.
        let other = Array(ReleaseFiles.imageText(repository: FakeRelease.ghcr, version: version,
                                                 digest: "sha256:" + String(repeating: "c", count: 64)).utf8)
        #expect(throws: ReleaseFiles.Problem(
            "udeck-plugin-image.txt is not the file SHA256SUMS names: its sha256 is \(ReleaseFiles.sha256(other)), "
            + "SHA256SUMS says \(ReleaseFiles.sha256(image)) — the two are not of one release")) {
            try ReleaseFiles.lock(sums: sums, image: other, version: version)
        }
        // The release asked for, not another.
        #expect(throws: ReleaseFiles.Problem("udeck-plugin-image.txt of v0.6.1 is of v0.6.0")) {
            try ReleaseFiles.lock(sums: sums, image: image, version: SemanticVersion(major: 0, minor: 6, patch: 1))
        }
    }

    @Test("sha256 is sha256sum's")
    func sha256() {
        #expect(ReleaseFiles.sha256([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ReleaseFiles.sha256(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Where pin reads a release, and how")
struct ReleaseSourceTests {
    @Test("GitHub's releases, unless UDECK_PLUGIN_DOWNLOAD_BASE says another place laid out the same way")
    func source() throws {
        #expect(try ReleaseSource(environment: [:]).base == "https://github.com/iillyyaa1997/udeck/releases/download")
        #expect(try ReleaseSource(environment: ["UDECK_PLUGIN_DOWNLOAD_BASE": ""]).base == ReleaseSource.github,
                "a CI variable left blank is no variable")
        let mirror = try ReleaseSource(environment: ["UDECK_PLUGIN_DOWNLOAD_BASE": "https://mirror.example/udeck/"])
        #expect(mirror.base == "https://mirror.example/udeck")
        #expect(mirror.url("SHA256SUMS", of: SemanticVersion(major: 0, minor: 6, patch: 0))
                == "https://mirror.example/udeck/v0.6.0/SHA256SUMS")
        #expect(mirror.latest("SHA256SUMS") == nil, "a mirror has no latest of its own")
        let github = try ReleaseSource(environment: [:])
        #expect(github.latest("udeck-plugin-image.txt")
                == "https://github.com/iillyyaa1997/udeck/releases/latest/download/udeck-plugin-image.txt")
        #expect(github.version(in: "https://github.com/iillyyaa1997/udeck/releases/download/v0.5.0/SHA256SUMS")
                == SemanticVersion(major: 0, minor: 5, patch: 0))
        #expect(github.version(in: "https://github.com/iillyyaa1997/udeck/releases/latest/download/SHA256SUMS") == nil)
        #expect(github.version(in: "https://release-assets.githubusercontent.com/v0.5.0/x") == nil)
        let local = try ReleaseSource(base: "file:///tmp/r/releases/download")
        #expect(local.scheme == "file" && github.scheme == "https")
        #expect(local.latest("x") == "file:///tmp/r/releases/latest/download/x")
    }

    @Test("not plain http, and nothing a path put after it would not mean", arguments: [
        ("http://mirror.example/udeck", "over plain http"),
        ("ftp://mirror.example/udeck", "an https:// or a file:// address"),
        ("mirror.example/udeck", "an https:// or a file:// address"),
        ("HTTPS://mirror.example", "an https:// or a file:// address"),
        ("https://mirror.example/udeck?token=x", "no space, query or fragment"),
        ("https://mirror.example/udeck#x", "no space, query or fragment"),
        ("https://mirror.example/u deck", "no space, query or fragment"),
        ("https://mirror.example/udeck\n", "no space, query or fragment"),
        ("https://", "names no place"),
        ("https:///", "names no place"),
    ])
    func refused(_ base: String, _ said: String) {
        do {
            let source = try ReleaseSource(base: base)
            Issue.record("\(base.debugDescription) taken as \(source.base)")
        } catch let problem as ReleaseSource.Problem {
            #expect(problem.description.contains(said), "\(problem.description)")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("curl is told how to fetch, and nothing of a .curlrc, in its arguments, and the address on its standard input")
    func curlArguments() {
        let url = "https://github.com/x/v1.0.0/SHA256SUMS"
        let arguments = Curl.arguments(for: url, output: "/tmp/f/body")
        #expect(arguments.first == "curl" && arguments.dropFirst().first == "-q", "-q is curl's first argument, or it reads ~/.curlrc")
        #expect(Array(arguments.suffix(2)) == ["--config", "-"], "the address is read from standard input")
        #expect(!arguments.contains { $0.contains("github.com") }, "the address is in no argument: \(arguments)")
        let joined = arguments.joined(separator: " ")
        for said in ["--proto =https ", "--proto-redir =https ", "--location --max-redirs 10", "--retry 3",
                     "--max-filesize 1048576", "--output /tmp/f/body", "--write-out %{http_code}\\n%{url_effective}\\n"] {
            #expect(joined.contains(said), "\(said) in \(joined)")
        }
        #expect(!joined.contains("--fail"), "a 404 is an answer, and --write-out says which address gave it")
        #expect(!joined.contains("--insecure") && !joined.contains(" -k "))
        #expect(Curl.arguments(for: "file:///r/v1.0.0/SHA256SUMS", output: "/b").joined(separator: " ").contains("--proto =file "))
        // One line of curl's config syntax: the address quoted, with a \ put
        // before each \ and " in it, so that curl reads it byte for byte.
        #expect(Curl.config(for: url) == Array("url = \"\(url)\"\n".utf8))
        let quoted: [UInt8] = Array((#"url = "https://a:p\"w\\d@m.example/u""# + "\n").utf8)
        #expect(Curl.config(for: #"https://a:p"w\d@m.example/u"#) == quoted)
    }

    @Test("what curl's run comes to: found, missing where it was asked last, or why not")
    func curlAnswers() throws {
        let url = "https://github.com/iillyyaa1997/udeck/releases/latest/download/SHA256SUMS"
        func answer(_ status: Int32, _ said: String, _ errors: String = "", file: [UInt8]? = nil, url: String = url) throws -> Fetched {
            try Curl.answer(status: status, said: Array(said.utf8), errors: Array(errors.utf8), file: file, url: url)
        }
        #expect(try answer(0, "200\nhttps://objects.example/x\n", file: [1, 2]) == .found([1, 2]))
        // Measured against GitHub, 2026-10-07: latest without the file is a 404
        // at the release GitHub sent it to, and curl exits 0 without --fail.
        let gone = "https://github.com/iillyyaa1997/udeck/releases/download/v0.5.0/SHA256SUMS"
        #expect(try answer(0, "404\n\(gone)\n", file: Array("Not Found".utf8)) == .missing(at: gone))
        #expect(try answer(0, "410\n\(gone)\n") == .missing(at: gone))
        // file://: no status, and exit 37 when there is no file.
        #expect(try answer(0, "000\nfile:///r/v1/x\n", file: [7], url: "file:///r/v1/x") == .found([7]))
        #expect(try answer(37, "000\nfile:///r/v1/x\n", "curl: (37) Couldn't open file", url: "file:///r/v1/x")
                == .missing(at: "file:///r/v1/x"))
        #expect(throws: FetchFailure(description: "could not read \(url): HTTP 000 from \(url)")) {
            try answer(0, "000\n\(url)\n", file: [])
        }
        #expect(throws: FetchFailure(description: "could not read \(url): HTTP 500 from https://x")) {
            try answer(0, "500\nhttps://x\n")
        }
        #expect(throws: FetchFailure(description: "could not read \(url): curl exited 6: curl: (6) Could not resolve host: github.com")) {
            try answer(6, "000\n\(url)\n", "curl: (6) Could not resolve host: github.com\n")
        }
        #expect(throws: FetchFailure(description: "pin reads a release with curl, and there is no curl on the PATH")) {
            try answer(127, "", "env: curl: No such file or directory\n")
        }
        #expect(throws: FetchFailure(description: "\(url) is larger than the 1048576 bytes pin reads")) {
            try answer(63, "200\n\(url)\n")
        }
        #expect(throws: FetchFailure(description: "\(url) is larger than the 1048576 bytes pin reads")) {
            try answer(0, "200\n\(url)\n", file: [UInt8](repeating: 0, count: Curl.largest + 1))
        }
        #expect(throws: FetchFailure.self) { try answer(0, "200", file: [1]) }
        #expect(throws: FetchFailure.self) { try answer(0, "200\n\(url)\n", file: nil) }
        #expect(throws: FetchFailure.self) { try answer(-1, "") }
    }

    /// A curl of the test's own, first on the PATH: it writes down what it was
    /// started with, what it read on its standard input and its whole
    /// environment, and serves one file — the address it was given on its
    /// standard input, as `--config -` gives it.
    func fakeCurl(in temp: TemporaryDirectory, code: String = "200") throws -> URL {
        let folder = temp.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let curl = folder.appendingPathComponent("curl")
        try Executable.write("""
            #!/bin/sh
            log="$FAKE_CURL_LOG"
            for argument in "$@"; do printf 'argument %s\\n' "$argument" >> "$log"; done
            config="$(cat)"
            printf '%s\\n' "$config" | sed 's/^/config /' >> "$log"
            env | LC_ALL=C sort | sed 's/^/environment /' >> "$log"
            output=""
            while [ $# -gt 1 ]; do
                [ "$1" = --output ] && output="$2"
                shift
            done
            url="$(printf '%s\\n' "$config" | sed -n 's/^url = "\\(.*\\)"$/\\1/p')"
            if [ "\(code)" = 200 ]; then printf 'served\\n' > "$output"; fi
            printf '%s\\n%s\\n' "\(code)" "$url"

            """, to: curl)
        return folder
    }

    @Test("curl gets the environment as it is — the proxy variables a CI sets among it — and nothing more")
    func curlEnvironment() throws {
        let temp = TemporaryDirectory()
        let bin = try fakeCurl(in: temp)
        let log = temp.url.appendingPathComponent("log")
        let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "FAKE_CURL_LOG": log.path,
                           "HTTPS_PROXY": "http://proxy.example:3128", "https_proxy": "http://lower.example:3128",
                           "NO_PROXY": "localhost,.internal", "ALL_PROXY": "socks5h://all.example:1080"]
        let scratch = temp.url.appendingPathComponent("scratch", isDirectory: true)
        let fetched = try Curl(environment: environment, scratch: scratch)
            .fetch("https://github.com/iillyyaa1997/udeck/releases/download/v1.0.0/SHA256SUMS")
        #expect(fetched == .found(Array("served\n".utf8)))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == "argument -q")
        #expect(lines.contains("config url = \"https://github.com/iillyyaa1997/udeck/releases/download/v1.0.0/SHA256SUMS\""))
        #expect(!lines.contains { $0.hasPrefix("argument ") && $0.contains("github.com") }, "the address is in no argument")
        let handed = lines.filter { $0.hasPrefix("environment ") }.map { String($0.dropFirst("environment ".count)) }
        for (name, value) in environment {
            #expect(handed.contains("\(name)=\(value)"), "\(name) reaches curl as it was")
        }
        // Only what it was given, and what a shell sets itself.
        let names = Set(handed.map { String($0.prefix { $0 != "=" }) })
        #expect(names.subtracting(environment.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"]).isEmpty, "\(names)")
        // The folder curl wrote into is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        withExtendedLifetime(temp) {}
    }

    @Test("no curl on the PATH says so")
    func noCurl() throws {
        let temp = TemporaryDirectory()
        #expect(throws: FetchFailure(description: "pin reads a release with curl, and there is no curl on the PATH")) {
            try Curl(environment: ["PATH": temp.url.path]).fetch("https://github.com/x")
        }
        withExtendedLifetime(temp) {}
    }

    @Test("a 404 is missing where curl asked last")
    func curlMissing() throws {
        let temp = TemporaryDirectory()
        let bin = try fakeCurl(in: temp, code: "404")
        let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "FAKE_CURL_LOG": temp.url.appendingPathComponent("log").path]
        #expect(try Curl(environment: environment).fetch("https://x.example/v1.0.0/SHA256SUMS")
                == .missing(at: "https://x.example/v1.0.0/SHA256SUMS"))
        withExtendedLifetime(temp) {}
    }

    /// A login in UDECK_PLUGIN_DOWNLOAD_BASE — what a private GitLab's generic
    /// packages ask for — reaches curl on its standard input, never among
    /// its arguments, where any process on the machine reads it; and nothing
    /// curl's answer comes to says it.
    @Test("a login in the address reaches curl on its standard input alone, and no message says it")
    func curlLogin() throws {
        let temp = TemporaryDirectory()
        let url = "https://ci:S3CRETTOKEN@mirror.example/udeck/v0.6.0/SHA256SUMS"
        let answers: [(code: String, fetched: Fetched)] = [("200", .found(Array("served\n".utf8))), ("404", .missing(at: url))]
        for (code, fetched) in answers {
            let bin = try fakeCurl(in: temp, code: code)
            let log = temp.url.appendingPathComponent("log-\(code)")
            let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "FAKE_CURL_LOG": log.path]
            #expect(try Curl(environment: environment).fetch(url) == fetched)
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            let arguments = lines.filter { $0.hasPrefix("argument ") }
            #expect(arguments.count > 10)
            #expect(!arguments.contains { $0.contains("S3CRET") || $0.contains("mirror.example") }, "\(arguments)")
            #expect(lines.contains("config url = \"\(url)\""), "the address, login and all, on standard input")
        }
        // Whatever curl's run comes to, a failure says the address with its
        // login as ***, curl's own words included.
        let failures: [(Int32, String, String)] = [
            (0, "500\n\(url)\n", "could not read https://***@mirror.example/udeck/v0.6.0/SHA256SUMS: HTTP 500 from "
                + "https://***@mirror.example/udeck/v0.6.0/SHA256SUMS"),
            (6, "000\n\(url)\n", "could not read https://***@mirror.example/udeck/v0.6.0/SHA256SUMS: curl exited 6: "
                + "curl: (6) Could not resolve host for https://***@mirror.example/udeck"),
            (63, "", "https://***@mirror.example/udeck/v0.6.0/SHA256SUMS is larger than the 1048576 bytes pin reads"),
            (-1, "", "curl was stopped by a signal while it read https://***@mirror.example/udeck/v0.6.0/SHA256SUMS"),
            (0, "200", "could not read https://***@mirror.example/udeck/v0.6.0/SHA256SUMS: curl said \"200\""),
        ]
        for (status, said, expected) in failures {
            do {
                _ = try Curl.answer(status: status, said: Array(said.utf8),
                                    errors: Array("curl: (6) Could not resolve host for https://ci:S3CRETTOKEN@mirror.example/udeck\n".utf8),
                                    file: nil, url: url)
                Issue.record("\(status) \(said.debugDescription) was an answer")
            } catch let failure as FetchFailure {
                #expect(failure.description == expected)
                #expect(!failure.description.contains("S3CRET"))
            }
        }
        withExtendedLifetime(temp) {}
    }

    @Test("an address is said with its login as ***, and as it is without one")
    func shownWithoutTheLogin() throws {
        #expect(ReleaseSource.shown(address: "https://ci:t0k@n@mirror.example/u@x/v1/") == "https://***@mirror.example/u@x/v1/")
        #expect(ReleaseSource.shown(address: "https://token@mirror.example") == "https://***@mirror.example")
        #expect(ReleaseSource.shown(address: ReleaseSource.github) == ReleaseSource.github)
        #expect(ReleaseSource.shown(address: "file:///r/download") == "file:///r/download")
        #expect(ReleaseSource.shown(address: "https://us er:pw@host/x") == "https://***@host/x", "a space is no end of an address")
        #expect(ReleaseSource.shown(text: "at https://a:b@one.example/x and https://c@two.example, not https://three.example/@x")
                == "at https://***@one.example/x and https://***@two.example, not https://three.example/@x")
        #expect(ReleaseSource.shown(text: "https://four.example said: write to ops@four.example")
                == "https://four.example said: write to ops@four.example", "an address ends at a space")
        let source = try ReleaseSource(base: "https://ci:S3CRETTOKEN@gitlab.example/api/v4/projects/7/packages/generic/udeck/")
        #expect(source.base == "https://ci:S3CRETTOKEN@gitlab.example/api/v4/projects/7/packages/generic/udeck",
                "the address itself is kept, login and all: curl needs it")
        #expect(source.shown == "https://***@gitlab.example/api/v4/projects/7/packages/generic/udeck")
        let github = try ReleaseSource(environment: [:])
        #expect(!source.isGitHub && github.isGitHub)
        // Refused, the address is said without its login too.
        for given in ["http://ci:S3CRETTOKEN@mirror.example/udeck", "ftp://ci:S3CRETTOKEN@mirror.example",
                      "https://ci:S3CRETTOKEN@mirror.example/udeck?x", "https://ci:S3CRET TOKEN@mirror.example/udeck"] {
            do {
                _ = try ReleaseSource(base: given)
                Issue.record("\(given) taken")
            } catch let problem as ReleaseSource.Problem {
                #expect(!problem.description.contains("S3CRET"), "\(problem.description)")
                #expect(problem.description.contains("://***@mirror.example"), "\(problem.description)")
            }
        }
    }

    /// The machine's own curl, on a release on disk: a Mac always has one, and
    /// so does the image (its check runs pin there). The Linux job's Swift
    /// image does not — swift-docker installs curl to fetch the toolchain and
    /// purges it after — so there this runs only where curl is.
    static let hasCurl: Bool = {
        #if canImport(Darwin)
        return true
        #else
        return ["/usr/bin/curl", "/bin/curl", "/usr/local/bin/curl"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        #endif
    }()

    @Test("the system's curl reads a file:// release, and says when a file is not there", .enabled(if: ReleaseSourceTests.hasCurl))
    func realCurl() throws {
        let temp = TemporaryDirectory()
        let folder = temp.url.appendingPathComponent("releases/download/v1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("sums\n".utf8).write(to: folder.appendingPathComponent("SHA256SUMS"))
        let curl = Curl(environment: ["PATH": "/usr/bin:/bin:/usr/local/bin"])
        let base = "file://" + temp.url.appendingPathComponent("releases/download").path
        #expect(try curl.fetch("\(base)/v1.0.0/SHA256SUMS") == .found(Array("sums\n".utf8)))
        #expect(try curl.fetch("\(base)/v1.0.0/udeck-plugin-image.txt") == .missing(at: "\(base)/v1.0.0/udeck-plugin-image.txt"))
        // The address read from standard input byte for byte: a " and a \
        // in it, quoted for curl's config, are the folder's own.
        let odd = temp.url.appendingPathComponent(#"a"b\c/download/v1.0.0"#, isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("odd\n".utf8).write(to: odd.appendingPathComponent("SHA256SUMS"))
        #expect(try curl.fetch("file://\(odd.path)/SHA256SUMS") == .found(Array("odd\n".utf8)))
        withExtendedLifetime(temp) {}
    }
}

@Suite("pin, from a release")
struct ReleasePinTests {
    let github = try! ReleaseSource(environment: [:])

    @Test("a version: its two files, held to one another, make the lock")
    func version() throws {
        let release = FakeRelease.release("0.6.0")
        let pinned = try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 6, patch: 0)), from: github, fetching: release)
        #expect(pinned.lock.version.description == "0.6.0")
        #expect(pinned.lock.image == "sha256:" + String(repeating: "d", count: 64))
        #expect(pinned.image == FakeRelease.ghcr)
        #expect(pinned.from == "https://github.com/iillyyaa1997/udeck/releases/download/v0.6.0/")
        for platform in PluginLock.platforms {
            #expect(pinned.lock.archives[platform] == ReleaseFiles.sha256(Array("\(platform) 0.6.0".utf8)))
        }
    }

    @Test("the latest: GitHub's latest image file says which, and that release's sums go with it")
    func latest() throws {
        var release = FakeRelease.release("0.6.0")
        release.add("0.7.0", digest: "sha256:" + String(repeating: "7", count: 64))
        release.latest("0.7.0")
        let pinned = try ReleasePin.pin(.latest, from: github, fetching: release)
        #expect(pinned.lock.version.description == "0.7.0")
        #expect(pinned.lock.image == "sha256:" + String(repeating: "7", count: 64))

        // A release published between the two requests: the latest image file
        // is 0.8.0's, and 0.8.0's sums are not there yet.
        var racing = release
        racing.files["https://github.com/iillyyaa1997/udeck/releases/latest/download/udeck-plugin-image.txt"] =
            Array(ReleaseFiles.imageText(repository: FakeRelease.ghcr, version: SemanticVersion(major: 0, minor: 8, patch: 0),
                                         digest: "sha256:" + String(repeating: "8", count: 64)).utf8)
        racing.redirects = [:]
        #expect(throws: ReleasePin.Failure.self) { try ReleasePin.pin(.latest, from: github, fetching: racing) }
        // ... and the sums of 0.8.0 there, of another image file: not of one release.
        racing.add("0.8.0", digest: "sha256:" + String(repeating: "9", count: 64))
        do {
            _ = try ReleasePin.pin(.latest, from: github, fetching: racing)
            Issue.record("two releases made one lock")
        } catch {
            #expect("\(error)".contains("is not the file SHA256SUMS names"), "\(error)")
        }
    }

    /// v0.5.0 and the releases before it carry neither file (measured on
    /// GitHub, 2026-10-07): `pin` says which release, and that a later one is
    /// needed.
    @Test("a release made before udeck-plugin was published with uDeck says so, by its version")
    func releaseWithoutTheAssets() throws {
        let empty = FakeRelease()
        #expect(throws: ReleasePin.Failure(description:
            "release v0.5.0 has no SHA256SUMS and no udeck-plugin-image.txt at "
            + "https://github.com/iillyyaa1997/udeck/releases/download/v0.5.0/: uDeck 0.5.0 and the releases before it "
            + "were made before udeck-plugin was published with them; udeck-plugin is published with uDeck's releases "
            + "from the one after 0.5.0 on — pin one of those, with --version X.Y.Z")) {
            try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 5, patch: 0)), from: github, fetching: empty)
        }
        // The latest, as GitHub has it today: sent to v0.5.0, which has nothing.
        var latest = FakeRelease()
        latest.latest("0.5.0")
        do {
            _ = try ReleasePin.pin(.latest, from: github, fetching: latest)
            Issue.record("pinned a release with nothing to pin")
        } catch {
            #expect("\(error)".hasPrefix("release v0.5.0 has no udeck-plugin-image.txt at "
                                         + "https://github.com/iillyyaa1997/udeck/releases/download/v0.5.0/: uDeck 0.5.0"),
                    "\(error)")
        }
        // A later release without them: none there, or made without them.
        do {
            _ = try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 9, patch: 0)), from: github, fetching: empty)
            Issue.record("pinned nothing")
        } catch {
            #expect("\(error)".contains("release v0.9.0 has no SHA256SUMS and no udeck-plugin-image.txt"), "\(error)")
            #expect("\(error)".contains("either there is no such release there, or it was made without udeck-plugin's assets"))
        }
        // One file of the two.
        var half = FakeRelease.release("0.6.0")
        half.files["\(FakeRelease.base)/v0.6.0/udeck-plugin-image.txt"] = nil
        do {
            _ = try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 6, patch: 0)), from: github, fetching: half)
            Issue.record("pinned half a release")
        } catch {
            #expect("\(error)".hasPrefix("release v0.6.0 has no udeck-plugin-image.txt at"), "\(error)")
        }
    }

    @Test("a mirror has no latest; a network that does not answer is said as it is")
    func elsewhere() throws {
        let mirror = try ReleaseSource(base: "https://mirror.example/udeck")
        do {
            _ = try ReleasePin.pin(.latest, from: mirror, fetching: FakeRelease())
            Issue.record("a latest from a mirror")
        } catch {
            #expect("\(error)".contains("has no latest release to ask for — say which with --version X.Y.Z"), "\(error)")
        }
        let release = FakeRelease.release("0.6.0", base: "https://mirror.example/udeck")
        #expect(try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 6, patch: 0)), from: mirror, fetching: release)
                .from == "https://mirror.example/udeck/v0.6.0/")
        var unreachable = release
        unreachable.unreachable = ["https://mirror.example/udeck/v0.6.0/SHA256SUMS"]
        #expect(throws: ReleasePin.Failure(description:
            "could not read https://mirror.example/udeck/v0.6.0/SHA256SUMS: curl exited 7: no route")) {
            try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 6, patch: 0)), from: mirror, fetching: unreachable)
        }
    }

    /// A mirror that takes a login: the files are read with it, and every
    /// address pin says — where the files came from, what is not there, what
    /// could not be read, whichever fetcher said it — says it as ***.
    @Test("a mirror's login is used and never said")
    func mirrorLogin() throws {
        let base = "https://ci:S3CRETTOKEN@gitlab.example/udeck"
        let mirror = try ReleaseSource(base: base)
        let version = SemanticVersion(major: 0, minor: 6, patch: 0)
        let release = FakeRelease.release("0.6.0", base: base)
        #expect(try ReleasePin.pin(.version(version), from: mirror, fetching: release).from == "https://***@gitlab.example/udeck/v0.6.0/")
        var unreachable = release
        unreachable.unreachable = ["\(base)/v0.6.0/SHA256SUMS"]
        var gone = release
        gone.files["\(base)/v0.6.0/udeck-plugin-image.txt"] = nil
        for (fetching, said) in [(unreachable, "could not read https://***@gitlab.example/udeck/v0.6.0/SHA256SUMS: curl exited 7"),
                                 (gone, "release v0.6.0 has no udeck-plugin-image.txt at https://***@gitlab.example/udeck/v0.6.0/:"),
                                 (FakeRelease(), "release v0.6.0 has no SHA256SUMS and no udeck-plugin-image.txt at https://***@")] {
            do {
                _ = try ReleasePin.pin(.version(version), from: mirror, fetching: fetching)
                Issue.record("pinned: \(said)")
            } catch {
                #expect("\(error)".hasPrefix(said), "\(error)")
                #expect(!"\(error)".contains("S3CRET"), "\(error)")
            }
        }
        do {
            _ = try ReleasePin.pin(.latest, from: mirror, fetching: release)
            Issue.record("a latest from a mirror")
        } catch {
            #expect("\(error)".hasPrefix("UDECK_PLUGIN_DOWNLOAD_BASE is https://***@gitlab.example/udeck, which"), "\(error)")
        }
    }
}

/// `udeck-plugin pin` as an author or a CI job runs it.
@Suite("The pin command")
struct PinCommandTests {
    struct Run {
        var status: Int32
        var output: [String]
        var errors: [String]
    }

    func pin(_ arguments: [String], release: FakeRelease, environment: [String: String] = [:], in here: String? = nil) async -> Run {
        var output: [String] = []
        var errors: [String] = []
        let status = await Command.run(["pin"] + arguments, environment: environment, currentDirectory: here,
                                       homes: .only(nil), fetching: release,
                                       output: { output.append($0) }, errors: { errors.append($0) })
        return Run(status: status, output: output, errors: errors)
    }

    /// A plugin repository's root: a passport, and nothing else needed.
    func repository() throws -> (TemporaryDirectory, URL) {
        let temp = TemporaryDirectory()
        let root = temp.url.appendingPathComponent("plugins-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins/x"), withIntermediateDirectories: true)
        try Data("{\"format\": 1, \"name\": \"Test\"}\n".utf8).write(to: root.appendingPathComponent("udeck-plugins.json"))
        return (temp, root)
    }

    func lock(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(".github/udeck-plugin.lock"), encoding: .utf8)
    }

    @Test("pin writes the lock file the release makes, and leaves one that is already it untouched")
    func writes() async throws {
        let (temp, root) = try repository()
        var release = FakeRelease.release("0.6.0")
        release.latest("0.6.0")
        let first = await pin(["--repo", root.path], release: release)
        #expect(first.status == 0, "\(first.errors)")
        let expected = try ReleasePin.pin(.version(SemanticVersion(major: 0, minor: 6, patch: 0)), from: ReleaseSource(environment: [:]),
                                          fetching: release).lock
        #expect(try lock(root) == expected.text)
        #expect(first.output.first == "pinned udeck-plugin 0.6.0 in \(root.path)/.github/udeck-plugin.lock, "
                + "from https://github.com/iillyyaa1997/udeck/releases/download/v0.6.0/")
        #expect(first.output.last == "  image  ghcr.io/iillyyaa1997/udeck-plugin@sha256:" + String(repeating: "d", count: 64))

        let file = root.appendingPathComponent(".github/udeck-plugin.lock")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        let again = await pin(["--repo", root.path, "--version", "0.6.0"], release: release)
        #expect(again.status == 0)
        #expect(again.output == ["\(root.path)/.github/udeck-plugin.lock already pins udeck-plugin 0.6.0; unchanged"])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                == Date(timeIntervalSince1970: 1_000_000), "not written again")
        #expect(before != nil)

        // Run in the repository, or a folder inside it: the repository is the
        // one that holds udeck-plugins.json.
        release.add("0.7.0", digest: "sha256:" + String(repeating: "7", count: 64))
        release.latest("0.7.0")
        let inside = await pin([], release: release, in: root.appendingPathComponent("plugins/x").path)
        #expect(inside.status == 0, "\(inside.errors)")
        #expect(try lock(root).hasPrefix("version=0.7.0\n"))
        let atRoot = await pin(["--version", "0.6.0"], release: release, in: root.path)
        #expect(atRoot.output.first?.hasPrefix("pinned udeck-plugin 0.6.0 in .github/udeck-plugin.lock") == true, "\(atRoot.output)")
        withExtendedLifetime(temp) {}
    }

    @Test("--check: 0 when the lock file is what its release has, 1 when not — and writes nothing")
    func check() async throws {
        let (temp, root) = try repository()
        var release = FakeRelease.release("0.6.0")
        release.add("0.7.0", digest: "sha256:" + String(repeating: "7", count: 64))
        release.latest("0.7.0")

        let none = await pin(["--repo", root.path, "--check"], release: release)
        #expect(none.status == 1)
        #expect(none.output == ["there is no \(root.path)/.github/udeck-plugin.lock: udeck-plugin pin writes it"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".github").path), "--check writes nothing")

        #expect(await pin(["--repo", root.path, "--version", "0.6.0"], release: release).status == 0)
        let pinned = try lock(root)
        let same = await pin(["--repo", root.path, "--check"], release: release)
        #expect(same.status == 0, "the release the lock file names: 0.6.0, though 0.7.0 is out")
        #expect(same.output.first?.contains("pins udeck-plugin 0.6.0 as its release has it") == true)
        let newest = await pin(["--repo", root.path, "--check", "--version", "latest"], release: release)
        #expect(newest.status == 1, "not the latest")
        #expect(newest.output.contains("  version: 0.6.0 here, 0.7.0 in the release"))
        #expect(newest.output.last == "udeck-plugin pin --version 0.7.0 writes it as the release has it")

        // One sum changed by hand.
        let x86 = try #require(pinned.split(separator: "\n").first { $0.hasPrefix("linux-x86_64=") })
        let changed = "linux-x86_64=" + String(repeating: "0", count: 64)
        try Data(pinned.replacingOccurrences(of: String(x86), with: changed).utf8)
            .write(to: root.appendingPathComponent(".github/udeck-plugin.lock"))
        let edited = await pin(["--repo", root.path, "--check"], release: release)
        #expect(edited.status == 1)
        #expect(edited.output.contains("  linux-x86_64: \(String(repeating: "0", count: 64)) here, \(x86.dropFirst("linux-x86_64=".count)) in the release"))
        #expect(try lock(root).contains(changed), "--check writes nothing")

        // One that does not read.
        try Data((pinned + "\n").utf8).write(to: root.appendingPathComponent(".github/udeck-plugin.lock"))
        let broken = await pin(["--repo", root.path, "--check"], release: release)
        #expect(broken.status == 1)
        #expect(broken.output == ["\(root.path)/.github/udeck-plugin.lock line 6 is empty; the file has no blank line: udeck-plugin pin writes it again"])
        let againstOne = await pin(["--repo", root.path, "--check", "--version", "0.6.0"], release: release)
        #expect(againstOne.status == 1)
        #expect(againstOne.output.first == "\(root.path)/.github/udeck-plugin.lock line 6 is empty; the file has no blank line")
        // pin writes it again, and says what was there.
        let rewritten = await pin(["--repo", root.path, "--version", "0.6.0"], release: release)
        #expect(rewritten.status == 0)
        #expect(rewritten.output.first == "note: \(root.path)/.github/udeck-plugin.lock line 6 is empty; the file has no blank line: "
                + "written again as the release has it")
        #expect(try lock(root) == pinned)
        withExtendedLifetime(temp) {}
    }

    @Test("a release that cannot be pinned is exit status 2, and the lock file stays as it was")
    func cannotPin() async throws {
        let (temp, root) = try repository()
        var release = FakeRelease()
        release.latest("0.5.0")
        let latest = await pin(["--repo", root.path], release: release)
        #expect(latest.status == 2)
        #expect(latest.errors.first?.hasPrefix("udeck-plugin pin: release v0.5.0 has no udeck-plugin-image.txt at ") == true,
                "\(latest.errors)")
        let named = await pin(["--repo", root.path, "--version", "0.5.0"], release: release)
        #expect(named.status == 2)
        #expect(named.errors.first?.contains("release v0.5.0 has no SHA256SUMS and no udeck-plugin-image.txt") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".github").path))
        let http = await pin(["--repo", root.path], release: FakeRelease.release("0.6.0"),
                             environment: ["UDECK_PLUGIN_DOWNLOAD_BASE": "http://mirror.example/udeck"])
        #expect(http.status == 2)
        #expect(http.errors.first?.contains("over plain http") == true)
        withExtendedLifetime(temp) {}
    }

    /// From anywhere but GitHub, pin says that the lock file holds what that
    /// place serves, and how to hold it to GitHub's release; and says the
    /// place with its login as ***.
    @Test("pinned from a mirror, the lock file is said to be the mirror's until it is checked against GitHub")
    func fromAMirror() async throws {
        let (temp, root) = try repository()
        let base = "https://ci:S3CRETTOKEN@gitlab.example/udeck"
        let mirror = ["UDECK_PLUGIN_DOWNLOAD_BASE": base]
        let release = FakeRelease.release("0.6.0", base: base)
        let note = "note: UDECK_PLUGIN_DOWNLOAD_BASE is https://***@gitlab.example/udeck, not GitHub's releases: the lock "
            + "file holds what that place serves — check it against GitHub's release with udeck-plugin pin --check, "
            + "UDECK_PLUGIN_DOWNLOAD_BASE unset, where GitHub can be reached"
        let written = await pin(["--repo", root.path, "--version", "0.6.0"], release: release, environment: mirror)
        #expect(written.status == 0, "\(written.errors)")
        #expect(written.output.first == "pinned udeck-plugin 0.6.0 in \(root.path)/.github/udeck-plugin.lock, "
                + "from https://***@gitlab.example/udeck/v0.6.0/")
        #expect(written.output.last == note)
        let unchanged = await pin(["--repo", root.path, "--version", "0.6.0"], release: release, environment: mirror)
        #expect(unchanged.output.last == note)
        let checked = await pin(["--repo", root.path, "--check"], release: release, environment: mirror)
        #expect(checked.status == 0)
        #expect(checked.output.last == note)
        let missing = await pin(["--repo", root.path, "--version", "0.6.1"], release: release, environment: mirror)
        #expect(missing.status == 2)
        for run in [written, unchanged, checked, missing] {
            #expect(!(run.output + run.errors).joined().contains("S3CRET"), "\(run.output) \(run.errors)")
        }
        // The lock file written from the mirror, checked against GitHub's
        // release: the same bytes there are a pass, others a failure.
        var github = FakeRelease.release("0.6.0")
        github.latest("0.6.0")
        let same = await pin(["--repo", root.path, "--check"], release: github)
        #expect(same.status == 0)
        #expect(same.output.count == 1, "no note from GitHub: \(same.output)")
        let other = await pin(["--repo", root.path, "--check"],
                              release: FakeRelease.release("0.6.0", digest: "sha256:" + String(repeating: "e", count: 64)))
        #expect(other.status == 1)
        withExtendedLifetime(temp) {}
    }

    @Test("pin is run in a plugin repository, or told where one is")
    func whichRepository() async throws {
        let temp = TemporaryDirectory()
        let release = FakeRelease.release("0.6.0")
        let nowhere = await pin(["--version", "0.6.0"], release: release, in: temp.url.path)
        #expect(nowhere.status == 2)
        #expect(nowhere.errors.first?.contains("is in no plugin repository") == true, "\(nowhere.errors)")
        let named = await pin(["--repo", temp.url.path, "--version", "0.6.0"], release: release)
        #expect(named.status == 2)
        #expect(named.errors == ["udeck-plugin pin: \(temp.url.path) is not a plugin repository: it has no udeck-plugins.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty, "nothing written")
        withExtendedLifetime(temp) {}
    }

    @Test("pin's arguments that make no sense are exit status 2, with the usage", arguments: [
        ["x"], ["--version"], ["--version", "v0.6.0"], ["--version", "0.6"], ["--version", "06.0.0"], ["--version", "Latest"],
        ["--version", "0.6.0", "--version", "0.6.1"], ["--repo"], ["--repo", ""], ["--repo="], ["--check=yes"], ["--strict"],
    ])
    func usage(_ arguments: [String]) async {
        let run = await pin(arguments, release: FakeRelease())
        #expect(run.status == 2, "\(arguments)")
        #expect(run.output.isEmpty)
        #expect(run.errors.joined().contains("usage: udeck-plugin"), "\(arguments): \(run.errors)")
    }

    @Test("the help names pin")
    func help() async {
        let run = await pin(["--version", "v1.0.0"], release: FakeRelease())
        #expect(run.errors.first?.hasPrefix("udeck-plugin pin: --version v1.0.0 is not X.Y.Z (the tag without its v) or latest") == true)
        #expect(Command.usage.contains("udeck-plugin pin [--version X.Y.Z | latest] [--repo <path>] [--check]"))
    }
}
