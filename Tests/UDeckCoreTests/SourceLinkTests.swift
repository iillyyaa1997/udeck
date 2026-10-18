import Foundation
import Testing
@testable import UDeckCore

/// An address pasted into **Add a source…** (stage 4, R1a), read before
/// anything is asked of its host: every form a browser shows, GitHub's and
/// GitLab's, and every one refused with what to paste instead.
@Suite("Source links")
struct SourceLinkTests {
    static let official = RepositoryAddress.official

    static func read(_ text: String) -> Result<SourceLink, SourceLink.Refusal> {
        SourceLink.read(text, official: official)
    }

    static func github(_ path: String) -> SourceLink { SourceLink(provider: "github", host: "github.com", path: path) }
    static func gitlab(_ host: String, _ path: String) -> SourceLink { SourceLink(provider: "gitlab", host: host, path: path) }

    static let read: [(String, SourceLink)] = [
        ("github.com/someone/team-plugins", github("someone/team-plugins")),
        ("https://github.com/someone/team-plugins", github("someone/team-plugins")),
        ("HTTPS://WWW.GitHub.com/Someone/Team-Plugins", github("Someone/Team-Plugins")),
        ("www.github.com/someone/team-plugins/", github("someone/team-plugins")),
        ("  https://github.com/someone/team-plugins\n", github("someone/team-plugins")),
        ("github.com/someone/team-plugins.git", github("someone/team-plugins")),
        ("github.com/someone/team-plugins/tree/main/plugins/uptime", github("someone/team-plugins")),
        ("github.com/someone/team-plugins/blob/main/README.md", github("someone/team-plugins")),
        ("github.com/someone/team-plugins/pull/3/files", github("someone/team-plugins")),
        ("github.com/someone/team-plugins/commit/a1b2c3d", github("someone/team-plugins")),
        ("github.com/someone/team-plugins?tab=readme#top", github("someone/team-plugins")),
        ("github.com/some-one/a.b_c-d", github("some-one/a.b_c-d")),
        ("github.com/someone/udeck%2Dplugins", github("someone/udeck-plugins")),
        ("github.com/iillyyaa1997/udeck-plugins-template", github("iillyyaa1997/udeck-plugins-template")),
        ("gitlab.com/group/project", gitlab("gitlab.com", "group/project")),
        ("https://gitlab.com/group/project", gitlab("gitlab.com", "group/project")),
        ("www.gitlab.com/group/project", gitlab("gitlab.com", "group/project")),
        ("gitlab.com/group/sub/deeper/project", gitlab("gitlab.com", "group/sub/deeper/project")),
        ("gitlab.com/group/project/-/tree/main/plugins/uptime", gitlab("gitlab.com", "group/project")),
        ("gitlab.com/group/project/-/merge_requests/1", gitlab("gitlab.com", "group/project")),
        ("gitlab.com/group/project/-/blob/main/README.md?ref_type=heads", gitlab("gitlab.com", "group/project")),
        ("gitlab.com/group/project.git", gitlab("gitlab.com", "group/project")),
        ("https://GitLab.Unicorns.Place/tools/udeck-plugins", gitlab("gitlab.unicorns.place", "tools/udeck-plugins")),
        ("https://gitlab.example:8443/Tools/UDeck_Plugins/-/tree/main", gitlab("gitlab.example:8443", "Tools/UDeck_Plugins")),
        ("https://gitlab.example:443/g/p", gitlab("gitlab.example", "g/p")),
        ("10.0.0.7:8080/g/p", gitlab("10.0.0.7:8080", "g/p")),
        ("gitlab.example/g/" + Array(repeating: "s", count: 19).joined(separator: "/"),
         gitlab("gitlab.example", "g/" + Array(repeating: "s", count: 19).joined(separator: "/"))),
        ("gitlab.example/g.x/p_y-z", gitlab("gitlab.example", "g.x/p_y-z")),
    ]

    @Test("every form a browser shows comes to the repository or the project", arguments: 0..<read.count)
    func reads(row: Int) throws {
        let (text, wanted) = Self.read[row]
        #expect(try Self.read(text).get() == wanted, "\(text)")
    }

    static let refused: [(String, SourceLink.Refusal)] = [
        ("", .empty),
        ("   \n", .empty),
        ("http://github.com/someone/team-plugins", .notHTTPS),
        ("HTTP://gitlab.example/g/p", .notHTTPS),
        ("git@github.com:someone/team-plugins.git", .ssh),
        ("git@gitlab.example:group/project.git", .ssh),
        ("ssh://git@gitlab.example:2222/group/project.git", .ssh),
        ("git+ssh://gitlab.example/group/project", .ssh),
        ("ftp://gitlab.example/g/p", .notALink),
        ("file:///Users/x/repo", .notALink),
        ("https://user:token@gitlab.example/g/p", .login),
        ("https://user@github.com/someone/team-plugins", .login),
        ("github.com", .notARepository(page: "github.com")),
        ("https://github.com/", .notARepository(page: "github.com")),
        ("github.com/someone", .notARepository(page: "someone")),
        ("github.com/orgs/someone/repositories", .notARepository(page: "orgs")),
        ("github.com/settings/tokens", .notARepository(page: "settings")),
        ("github.com/Settings/tokens", .notARepository(page: "Settings")),
        ("github.com/marketplace/x", .notARepository(page: "marketplace")),
        ("gist.github.com/someone/0123456789abcdef", .notARepository(page: "gist.github.com")),
        ("api.github.com/repos/someone/team-plugins", .notARepository(page: "api.github.com")),
        ("raw.githubusercontent.com/someone/team-plugins/main/x", .notARepository(page: "raw.githubusercontent.com")),
        ("github.com/iillyyaa1997/udeck-plugins", .officialCatalogue),
        ("https://github.com/IILLYYAA1997/UDeck-Plugins/tree/main/plugins/uptime", .officialCatalogue),
        ("github.com/iillyyaa1997/udeck-plugins.git", .officialCatalogue),
        ("github.com:8443/someone/team-plugins", .notALink),
        ("github.com/some one/team-plugins", .notALink),
        ("github.com/someone/..", .notALink),
        ("github.com/someone/team-plugins%", .notALink),
        ("gitlab.com", .notAProject),
        ("gitlab.com/group", .notAProject),
        ("gitlab.com/group/-/project", .notAProject),
        ("gitlab.com/-/group/project", .notAProject),
        ("gitlab.com/group/.hidden", .notAProject),
        ("gitlab.com/group/-dash", .notAProject),
        ("gitlab.com/group/pro ject", .notAProject),
        ("gitlab.com/group/проект", .notAProject),
        ("gitlab.example/g/" + Array(repeating: "s", count: 20).joined(separator: "/"), .notAProject),
        ("localhost/g/p", .notALink),
        ("gitlab.example:0/g/p", .notALink),
        ("gitlab.example:65536/g/p", .notALink),
        ("gitlab.example:/g/p", .notALink),
        ("-gitlab.example/g/p", .notALink),
        ("gitlab..example/g/p", .notALink),
        ("gitlab_example.com/g/p", .notALink),
        ("гитлаб.рф/g/p", .notALink),
        ("[::1]/g/p", .notALink),
        ("https://", .notALink),
        ("İ://gitlab.example/g/p", .notALink),
        ("İİİhttps://github.com/someone/team-plugins", .notALink),
    ]

    @Test("every address refused before any request, with what it is", arguments: 0..<refused.count)
    func refuses(row: Int) {
        let (text, wanted) = Self.refused[row]
        #expect(Self.read(text) == .failure(wanted), "\(text)")
    }

    /// The same official repository in a lab build: whatever `Info.plist`
    /// names is the official catalogue, refused as one.
    @Test("the official repository is the one given, whatever it is called")
    func officialIsGiven() {
        let lab = RepositoryAddress(path: "lab/fake-plugins")
        #expect(SourceLink.read("github.com/lab/fake-plugins", official: lab) == .failure(.officialCatalogue))
        #expect(SourceLink.read("github.com/iillyyaa1997/udeck-plugins", official: lab)
                == .success(Self.github("iillyyaa1997/udeck-plugins")))
    }

    @Test("what a source in sources.json has to be: an address that reads back as itself")
    func readsBackAsItself() {
        let official = Self.official
        #expect(SourceLink.refusal(of: Self.github("someone/team-plugins").address, official: official) == nil)
        #expect(SourceLink.refusal(of: Self.gitlab("gitlab.example:8443", "g/s/p").address, official: official) == nil)
        #expect(SourceLink.refusal(of: RepositoryAddress(provider: "gitlab", host: "github.com", path: "o/r"), official: official)
                == .readsAsAnother("github.com/o/r"))
        #expect(SourceLink.refusal(of: RepositoryAddress(path: "settings/x"), official: official)
                == .notARepository(page: "settings"))
        #expect(Self.github("o/r").page == "https://github.com/o/r" && Self.gitlab("h.example:8443", "g/p").page
                == "https://h.example:8443/g/p", "what Add as a source… fills the field with")
    }

    static let refusals: [SourceLink.Refusal] = [
        .empty, .notALink, .notHTTPS, .ssh, .login, .notARepository(page: "settings"),
        .notARepository(page: "gist.github.com"), .officialCatalogue, .notAProject, .readsAsAnother("gitlab.com/g/p"),
    ]

    /// Each refusal says what to paste instead, in both languages, and never
    /// the same words in both.
    @Test("every refusal is said in both languages, with what it names", arguments: Language.allCases)
    func refusalsAreSaid(language: Language) {
        let strings = Strings(language)
        for refusal in Self.refusals {
            let said = strings(.sourceLinkRefused(refusal, official: "github.com/o/r"))
            #expect(!said.isEmpty && said != Strings(language == .english ? .russian : .english)(
                .sourceLinkRefused(refusal, official: "github.com/o/r")), "\(refusal)")
            switch refusal {
            case .notHTTPS: #expect(said.contains("HTTPS") && said.contains("https://"))
            case .notARepository(let page): #expect(said.contains(page.contains(".") ? page : "github.com/\(page)"))
            case .officialCatalogue: #expect(said.contains("github.com/o/r"))
            case .readsAsAnother(let other): #expect(said.contains(other))
            case .empty, .notALink:
                #expect(said.contains("github.com/") && said.contains("gitlab.com/"), "what to paste instead")
            default: break
            }
        }
    }
}
