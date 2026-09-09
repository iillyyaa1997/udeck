import Foundation
import Testing
@testable import UDeckCore

@Suite("Plugin identifiers")
struct PluginIdentifierTests {
    @Test("ordinary ids are accepted", arguments: ["disk-space", "a", "x.y_z", "plugin9"])
    func accepts(_ raw: String) {
        #expect(PluginIdentifier(rawValue: raw) != nil)
    }

    @Test("ids that would be ambiguous as a path or a variable are refused",
          arguments: ["", "..", ".", "Has-Capitals", "with space", "a/b", "-leading", String(repeating: "x", count: 65)])
    func refuses(_ raw: String) {
        #expect(PluginIdentifier(rawValue: raw) == nil)
    }

    @Test("a setting key becomes a predictable environment variable")
    func environmentKey() {
        #expect(PluginIdentifier.settingEnvironmentKey("show_waiting_only") == "UDECK_SETTING_SHOW_WAITING_ONLY")
        #expect(PluginIdentifier.settingEnvironmentKey("rows") == "UDECK_SETTING_ROWS")
    }

    @Test("decoding a bad id fails with a message that names the rule")
    func decodeFailsLoudly() {
        let json = Data("\"NOT VALID\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PluginIdentifier.self, from: json)
        }
    }
}

@Suite("Manifest validation")
struct ManifestTests {
    func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test("a well-formed poll manifest has no problems")
    func validManifest() throws {
        let m = try manifest("""
        { "id": "ok-plugin", "name": "OK", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 3 }
        """)
        #expect(m.problems().isEmpty)
        #expect(m.permissions.isEmpty)
        #expect(m.window.defaultWidth == 4)
    }

    @Test("a manifest from a future contract is refused rather than guessed at")
    func futureAPIRefused() throws {
        let m = try manifest("""
        { "id": "future", "name": "Future", "version": "1.0.0", "api": 99, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 3 }
        """)
        #expect(m.problems().contains { if case .unsupportedAPI = $0 { true } else { false } })
    }

    @Test("a poll plugin without an interval or a timeout is rejected")
    func pollNeedsSchedule() throws {
        let m = try manifest("""
        { "id": "p", "name": "P", "version": "1.0.0", "api": 1, "kind": "poll", "run": ["./x"] }
        """)
        #expect(m.problems().contains(.missingInterval))
        #expect(m.problems().contains(.missingTimeout))
    }

    @Test("a timeout at least as long as the interval is rejected, because runs would overlap")
    func timeoutMustBeShorterThanInterval() throws {
        let m = try manifest("""
        { "id": "p", "name": "P", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./x"], "interval": 3, "timeout": 3 }
        """)
        #expect(m.problems().contains(.timeoutNotShorterThanInterval(timeout: 3, interval: 3)))
    }

    @Test("the resident kind parses but is reported as not implemented yet")
    func residentParsesAndIsRefused() throws {
        let m = try manifest("""
        { "id": "term", "name": "Terminal", "version": "1.0.0", "api": 1, "kind": "resident",
          "run": ["./pty"], "restart": { "mode": "on-failure", "initialBackoff": 1,
          "maximumBackoff": 30, "backoffFactor": 2 } }
        """)
        #expect(m.kind == .resident)
        #expect(m.restart?.mode == .onFailure)
        #expect(m.problems() == [.residentNotSupportedYet])
    }

    @Test("every problem is reported at once, not one per attempt")
    func reportsEveryProblem() throws {
        let m = try manifest("""
        { "id": "p", "name": "  ", "version": "1.0.0", "api": 1, "kind": "poll", "run": [] }
        """)
        let problems = m.problems()
        #expect(problems.contains(.blankName))
        #expect(problems.contains(.emptyRunCommand))
        #expect(problems.contains(.missingInterval))
        #expect(problems.count >= 3)
    }

    @Test("two settings sharing a key are caught")
    func duplicateSettingKeys() throws {
        let m = try manifest("""
        { "id": "p", "name": "P", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./x"], "interval": 5, "timeout": 2,
          "settings": [ {"key":"a","type":"bool","default":true,"label":"A"},
                        {"key":"a","type":"bool","default":false,"label":"A again"} ] }
        """)
        #expect(m.problems().contains(.duplicateSettingKey("a")))
    }

    @Test("permissions decode into the capabilities the operator is asked about")
    func permissionsBecomeCapabilities() throws {
        let m = try manifest("""
        { "id": "p", "name": "P", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./x"], "interval": 5, "timeout": 2,
          "permissions": { "read": ["/tmp/a-*"], "exec": ["ps"], "screen": true } }
        """)
        #expect(m.permissions.capabilities == [.read("/tmp/a-*"), .exec("ps"), .screen])
    }
}

@Suite("Setting declarations")
struct SettingDeclarationTests {
    @Test("a default of the wrong type is caught")
    func typeMismatch() {
        let d = SettingDeclaration(key: "n", type: .int, label: "N", defaultValue: .string("x"))
        #expect(d.problem != nil)
    }

    @Test("an enum must list its options and default to one of them")
    func enumNeedsOptions() {
        let missing = SettingDeclaration(key: "g", type: .enumeration, label: "G", defaultValue: .string("all"))
        #expect(missing.problem != nil)

        let wrong = SettingDeclaration(
            key: "g", type: .enumeration, label: "G", defaultValue: .string("nope"),
            options: [SettingOption(value: "all", label: "All")]
        )
        #expect(wrong.problem != nil)

        let good = SettingDeclaration(
            key: "g", type: .enumeration, label: "G", defaultValue: .string("all"),
            options: [SettingOption(value: "all", label: "All")]
        )
        #expect(good.problem == nil)
    }

    @Test("a stored value outside the declared range is brought back into it")
    func coerceClamps() {
        let d = SettingDeclaration(key: "rows", type: .int, label: "Rows",
                                   defaultValue: .int(8), minimum: 1, maximum: 20)
        #expect(d.coerce(.int(99)) == .int(20))
        #expect(d.coerce(.int(-4)) == .int(1))
        #expect(d.coerce(.int(9)) == .int(9))
    }

    @Test("a stored value of the wrong type falls back to the default rather than crashing")
    func coerceFallsBack() {
        let d = SettingDeclaration(key: "rows", type: .int, label: "Rows", defaultValue: .int(8))
        #expect(d.coerce(.string("nonsense")) == .int(8))
    }

    @Test("values reach the plugin as JSON, so it can tell false from \"false\"")
    func jsonLiterals() {
        #expect(SettingValue.bool(false).jsonLiteral == "false")
        #expect(SettingValue.int(12).jsonLiteral == "12")
        #expect(SettingValue.string("12").jsonLiteral == "\"12\"")
        #expect(SettingValue.string("say \"hi\"").jsonLiteral == "\"say \\\"hi\\\"\"")
    }
}
