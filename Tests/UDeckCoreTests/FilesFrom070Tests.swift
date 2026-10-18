import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// The files 0.7.0 wrote, as it wrote them — each made by 0.7.0's own stores
/// (`JSONFileStore` at 43db3a8, the release), not typed by hand: `installed.json`
/// with a verified copy that updated itself, a pull request's, a fork's branch
/// whose previous copy has no repository, and a first install; `grants.json`
/// with decisions held to a version and to a tree; `followed.json` and
/// `state.json` of the official catalogue; and `settings.json` with both
/// switches off. Stage 4 adds no key to any of them: each reads, means what it
/// meant, and is written back byte for byte — `settings.json` but for the
/// order of a set, which 0.7.0 does not keep from one run to the next either.
@Suite("Files 0.7.0 wrote")
struct FilesFrom070Tests {
    let udeck = TemporaryDirectory()

    static let installed = #"""
        {
          "plugins" : {
            "asks-nothing" : {
              "commit" : "3333333333333333333333333333333333333333",
              "installedAt" : "2026-09-21T14:13:20Z",
              "pinned" : false,
              "previous" : {
                "commit" : "1111111111111111111111111111111111111111",
                "ref" : {
                  "kind" : "default",
                  "name" : "main"
                },
                "repository" : {
                  "host" : "github.com",
                  "path" : "iillyyaa1997/udeck-plugins",
                  "provider" : "github"
                },
                "tree" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "version" : "1.0.0"
              },
              "ref" : {
                "kind" : "pr",
                "name" : "3"
              },
              "repository" : {
                "host" : "github.com",
                "path" : "iillyyaa1997/udeck-plugins",
                "provider" : "github"
              },
              "source" : "official",
              "tree" : "dddddddddddddddddddddddddddddddddddddddd",
              "verification" : {
                "by" : null,
                "checkedAgainst" : "2222222222222222222222222222222222222222",
                "checkedAt" : "2026-09-21T14:13:20Z",
                "status" : "unverified"
              },
              "version" : "1.0.1"
            },
            "cpu" : {
              "commit" : "ffffffffffffffffffffffffffffffffffffffff",
              "installedAt" : "2026-09-21T14:13:20Z",
              "pinned" : true,
              "previous" : {
                "commit" : "1111111111111111111111111111111111111111",
                "ref" : {
                  "kind" : "default",
                  "name" : "main"
                },
                "tree" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "version" : "1.0.0"
              },
              "ref" : {
                "kind" : "branch",
                "name" : "x"
              },
              "repository" : {
                "host" : "github.com",
                "path" : "someone/udeck-plugins",
                "provider" : "github"
              },
              "source" : "official",
              "tree" : "dddddddddddddddddddddddddddddddddddddddd",
              "verification" : {
                "by" : null,
                "checkedAgainst" : "2222222222222222222222222222222222222222",
                "checkedAt" : "2026-09-21T14:13:20Z",
                "status" : "modified"
              },
              "version" : "0.9.0"
            },
            "disk" : {
              "commit" : "1111111111111111111111111111111111111111",
              "installedAt" : "2026-09-21T14:13:20Z",
              "pinned" : false,
              "previous" : null,
              "ref" : {
                "kind" : "default",
                "name" : "main"
              },
              "repository" : {
                "host" : "github.com",
                "path" : "iillyyaa1997/udeck-plugins",
                "provider" : "github"
              },
              "source" : "official",
              "tree" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "verification" : {
                "by" : "official",
                "checkedAgainst" : null,
                "checkedAt" : "2026-09-21T14:13:20Z",
                "status" : "verified"
              },
              "version" : "1.0.0"
            },
            "uptime" : {
              "automatic" : true,
              "commit" : "2222222222222222222222222222222222222222",
              "installedAt" : "2026-09-22T14:13:20Z",
              "pinned" : false,
              "previous" : {
                "commit" : "1111111111111111111111111111111111111111",
                "ref" : {
                  "kind" : "default",
                  "name" : "main"
                },
                "repository" : {
                  "host" : "github.com",
                  "path" : "iillyyaa1997/udeck-plugins",
                  "provider" : "github"
                },
                "tree" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "version" : "1.0.0"
              },
              "ref" : {
                "kind" : "default",
                "name" : "main"
              },
              "repository" : {
                "host" : "github.com",
                "path" : "iillyyaa1997/udeck-plugins",
                "provider" : "github"
              },
              "source" : "official",
              "tree" : "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "verification" : {
                "by" : "official",
                "checkedAgainst" : "2222222222222222222222222222222222222222",
                "checkedAt" : "2026-09-22T14:13:20Z",
                "status" : "verified"
              },
              "version" : "1.1.0"
            }
          },
          "version" : 1
        }
        """#

    static let grants = #"""
        {
          "byPlugin" : {
            "asks-nothing" : {
              "decidedAt" : "2026-09-21T14:13:20Z",
              "decidedForTree" : "dddddddddddddddddddddddddddddddddddddddd",
              "decidedForVersion" : "1.0.1",
              "denied" : [

              ],
              "granted" : [

              ]
            },
            "cpu" : {
              "decidedAt" : "2026-09-21T14:13:20Z",
              "decidedForTree" : "dddddddddddddddddddddddddddddddddddddddd",
              "decidedForVersion" : "0.9.0",
              "denied" : [
                {
                  "family" : "network",
                  "scope" : "example.com"
                }
              ],
              "granted" : [
                {
                  "family" : "read",
                  "scope" : "~/notes/*"
                }
              ]
            },
            "uptime" : {
              "decidedAt" : "2026-09-22T14:13:20Z",
              "decidedForVersion" : "1.1.0",
              "denied" : [

              ],
              "granted" : [
                {
                  "family" : "exec",
                  "scope" : "sysctl"
                }
              ]
            }
          },
          "version" : 1
        }
        """#

    static let followed = #"""
        {
          "branches" : {
            "cpu" : {
              "checkedAt" : "2026-09-22T14:13:20Z",
              "head" : "ffffffffffffffffffffffffffffffffffffffff",
              "name" : "x",
              "repository" : {
                "host" : "github.com",
                "path" : "someone/udeck-plugins",
                "provider" : "github"
              }
            }
          },
          "notCheckedSince" : {
            "cpu" : "2026-09-21T14:13:20Z"
          },
          "pulls" : {
            "asks-nothing" : {
              "base" : "main",
              "checkedAt" : "2026-09-22T14:13:20Z",
              "head" : "3333333333333333333333333333333333333333",
              "history" : {
                "checkedAt" : "2026-09-22T14:13:20Z",
                "from" : "3333333333333333333333333333333333333333",
                "rewritten" : false,
                "to" : "3333333333333333333333333333333333333333"
              },
              "merged" : false,
              "number" : 3,
              "state" : "open"
            }
          },
          "version" : 1
        }
        """#

    static let state = #"""
        {
          "defaultBranch" : "main",
          "defaultBranchReadAt" : "2026-09-21T14:13:20Z",
          "etag" : "W/\"e\"",
          "failuresInARow" : 1,
          "head" : "2222222222222222222222222222222222222222",
          "lastAttempt" : "2026-09-22T14:13:20Z",
          "lastError" : {
            "rateLimited" : {
              "until" : "2026-09-22T14:13:20Z"
            }
          },
          "lastSuccess" : "2026-09-22T14:13:20Z",
          "rateLimit" : {
            "remaining" : 41,
            "reset" : "2026-09-21T15:13:20Z"
          }
        }
        """#

    static let settings = #"""
        {
          "autoUpdateVerified" : false,
          "collapseOnAppSwitch" : true,
          "defaultCardTTL" : 60,
          "density" : "normal",
          "gesture" : {

          },
          "hotkey" : {
            "enabled" : true,
            "key" : "U",
            "modifiers" : [
              "control",
              "option"
            ]
          },
          "look" : {
            "glass" : {
              "opacity" : 1,
              "style" : "regular",
              "tintIsLight" : true,
              "tintStrength" : 0.72,
              "tinted" : true
            },
            "ink" : "dark",
            "inkBrightness" : 1,
            "presence" : 1
          },
          "officialCatalogue" : false,
          "panel" : {

          },
          "pluginExecutableSearchPath" : [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
          ],
          "pollWhileCollapsed" : false,
          "resolvedIsDark" : false,
          "silentTTLMultiplier" : 3,
          "theme" : {
            "dark" : {
              "glass" : {
                "opacity" : 1,
                "style" : "regular",
                "tintIsLight" : false,
                "tintStrength" : 0.55,
                "tinted" : true
              },
              "ink" : "light",
              "inkBrightness" : 1,
              "presence" : 1
            },
            "light" : {
              "glass" : {
                "opacity" : 1,
                "style" : "regular",
                "tintIsLight" : true,
                "tintStrength" : 0.72,
                "tinted" : true
              },
              "ink" : "dark",
              "inkBrightness" : 1,
              "presence" : 1
            },
            "manualIsDark" : false,
            "saved" : [

            ],
            "schedule" : {
              "darkFromHour" : 19,
              "lightFromHour" : 7
            },
            "source" : "manual",
            "states" : {
              "dark" : {

              },
              "light" : {

              },
              "links" : [
                {
                  "id" : "4CF9FDF8-8DB0-42CA-B072-16FC9149C18E",
                  "states" : [
                    "collapsed.ordinary",
                    "peek.ordinary",
                    "open.ordinary",
                    "fullscreen.ordinary",
                    "collapsed.fullscreen",
                    "peek.fullscreen",
                    "open.fullscreen",
                    "fullscreen.fullscreen"
                  ]
                }
              ],
              "shared" : [

              ]
            }
          },
          "version" : 1
        }
        """#


    static func roundTrip<Value: Codable & Equatable & Sendable>(_ text: String, as type: Value.Type) throws -> (Value, String) {
        let value = try JSONFileStore<Value>.decoder.decode(Value.self, from: Data(text.utf8))
        let written = String(decoding: try JSONFileStore<Value>.encoder.encode(value), as: UTF8.self)
        return (value, written)
    }

    @Test("installed.json from 0.7.0 reads, every copy the official source's as it was, and is written back byte for byte")
    func installed() throws {
        let (records, written) = try Self.roundTrip(Self.installed, as: InstalledPlugins.self)
        #expect(written == Self.installed)
        #expect(records.plugins.keys.sorted() == ["asks-nothing", "cpu", "disk", "uptime"])
        #expect(records.plugins.values.allSatisfy { $0.source == InstalledPlugins.officialSource && $0.origin.source == "official" })
        let uptime = try #require(records.plugins["uptime"])
        #expect(uptime.automatic == true && uptime.verification.status == .verified && uptime.isOfficialDefault)
        #expect(records.plugins["asks-nothing"]?.ref == .pullRequest(3) && records.plugins["cpu"]?.ref == .branch("x"))
        #expect(records.plugins["cpu"]?.verification.status == .modified && records.plugins["cpu"]?.previous?.repository == nil)
        #expect(records.plugins["disk"]?.previous == nil)
        // Which source each previous copy is of: the official one, by the
        // rules that need nothing a 0.7.0 file lacks.
        for (id, record) in records.plugins {
            guard let previous = record.previous else { continue }
            guard case .source(let origin) = previous.source(record: record, official: .official, sources: []) else {
                Issue.record("\(id)'s previous copy is of no source"); continue
            }
            #expect(origin.source == "official" && origin.repository == (previous.repository ?? .official), "\(id)")
        }
        // What every row of the official catalogue says of them is what it said.
        let entry = CatalogueEntry(id: "uptime", listing: FakeRepository.withUptime().plugin("uptime"),
                                   verdict: RepositoryRules.check(folder: "uptime", listing: FakeRepository.withUptime().plugin("uptime"),
                                                                  manifest: FakeRepository.withUptime().data(at: "plugins/uptime/manifest.json"),
                                                                  udeck: SemanticVersion("0.7.0")))
        for record in records.plugins.values {
            #expect(CatalogueRowState.of(entry, record: record, folderExists: true, source: "official")
                    == CatalogueRowState.of(entry, record: record, folderExists: true))
            #expect(UpdateOffer.offered(record, head: entry, source: "official") == UpdateOffer.offered(record, head: entry))
        }
    }

    @Test("grants.json from 0.7.0 reads — decisions held to a version and to a tree — and is written back byte for byte")
    func grants() throws {
        let (grants, written) = try Self.roundTrip(Self.grants, as: PermissionGrants.self)
        #expect(written == Self.grants)
        #expect(grants.byPlugin["uptime"]?.decidedForTree == nil && grants.byPlugin["uptime"]?.granted == [.exec("sysctl")])
        #expect(grants.byPlugin["asks-nothing"]?.decidedForTree == String(repeating: "d", count: 40))
        #expect(grants.byPlugin["cpu"]?.denied == [.network("example.com")])
    }

    @Test("followed.json and state.json from 0.7.0 read, and are written back byte for byte")
    func catalogueFiles() throws {
        let (followed, writtenFollowed) = try Self.roundTrip(Self.followed, as: FollowedRefs.self)
        #expect(writtenFollowed == Self.followed)
        #expect(followed.pulls["asks-nothing"]?.number == 3 && followed.branches["cpu"]?.repository?.path == "someone/udeck-plugins")
        let (state, writtenState) = try Self.roundTrip(Self.state, as: CatalogueState.self)
        #expect(writtenState == Self.state)
        #expect(state.head == String(repeating: "2", count: 40) && state.rateLimit.remaining == 41)
        #expect(state.lastError == .rateLimited(until: Date(timeIntervalSince1970: 1_790_086_400)))
    }

    /// Byte for byte but for one thing 0.7.0 did not keep either: the
    /// shortcut's modifiers are a set, written in whatever order a run of
    /// uDeck holds them — 0.7.0's own runs differ there.
    @Test("settings.json from 0.7.0 reads, both switches off, and is written back the same, a set's order aside")
    func settings() throws {
        let (settings, written) = try Self.roundTrip(Self.settings, as: AppSettings.self)
        #expect(!settings.readsOfficialCatalogue && !settings.updatesVerifiedByThemselves)
        #expect(try JSONFileStore<AppSettings>.decoder.decode(AppSettings.self, from: Data(written.utf8)) == settings)
        func object(_ text: String) throws -> NSDictionary {
            var object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            if var hotkey = object["hotkey"] as? [String: Any], let modifiers = hotkey["modifiers"] as? [String] {
                hotkey["modifiers"] = modifiers.sorted()
                object["hotkey"] = hotkey
            }
            return NSDictionary(dictionary: object)
        }
        #expect(try object(written) == object(Self.settings))
        #expect(written.count == Self.settings.count, "nothing added, nothing left out")
    }

    /// A ~/.udeck 0.7.0 left: no sources.json, which is no source added.
    @Test("a uDeck folder from 0.7.0 has no sources.json, which is no source added")
    func noSourcesFile() throws {
        try JSONFileStore<InstalledPlugins>(url: udeck.paths.installedFile).save(
            try JSONFileStore<InstalledPlugins>.decoder.decode(InstalledPlugins.self, from: Data(Self.installed.utf8)))
        #expect(!FileManager.default.fileExists(atPath: udeck.paths.sourcesFile.path))
        #expect(try SourceStore(paths: udeck.paths).load().get() == SourceList())
    }
}
