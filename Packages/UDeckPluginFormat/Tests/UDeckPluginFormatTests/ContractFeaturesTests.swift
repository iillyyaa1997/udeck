import Foundation
import Testing
@testable import UDeckPluginFormat

/// The registry of which uDeck release first had each part of the plugin
/// contract, and `minUDeck` worked out from it (rule 19).
@Suite("The contract's releases")
struct ContractFeaturesTests {
    /// Every part of the contract, listed from the code that reads it — the
    /// decoders' keys and the enums' cases — never from a list of its own.
    /// What a producer and a card's action are handed is listed from the app,
    /// in its tests (`PollExecutionTests.environmentIsDated`,
    /// `actionEnvironmentIsDated`), where those environments are built. What
    /// the decoder reads outside the contract — `restart` — is not in it.
    static var fromTheCode: [ContractFeature] {
        var features: [ContractFeature] = []
        features += PluginManifest.CodingKeys.allCases.map(\.stringValue)
            .filter { !ContractFeatures.outsideTheContract.contains($0) }.map { .manifestField($0) }
        features += PluginKind.allCases.map { .pluginKind($0.rawValue) }
        features += PermissionRequest.CodingKeys.allCases.map { .permission($0.stringValue) }
        features += WindowHints.CodingKeys.allCases.map { .windowField($0.stringValue) }
        features += SettingDeclaration.CodingKeys.allCases.map { .settingField($0.stringValue) }
        features += SettingDeclaration.Kind.allCases.map { .settingType($0.rawValue) }
        features += SettingOption.CodingKeys.allCases.map { .optionField($0.stringValue) }
        features.append(.translations)
        features += ManifestTranslation.CodingKeys.allCases.map { .translationField($0.stringValue) }
        features += SettingTranslation.CodingKeys.allCases.map { .settingTranslationField($0.stringValue) }
        features += Card.CodingKeys.allCases.map { .cardField($0.stringValue) }
        features += CardState.allCases.map { .cardState($0.rawValue) }
        features += CardRow.Kind.allCases.map { .row($0.rawValue) }
        features += MeterRow.CodingKeys.allCases.map { .rowField(row: "meter", field: $0.stringValue) }
        features += ListItem.CodingKeys.allCases.map { .rowField(row: "list", field: $0.stringValue) }
        features += SparkRow.CodingKeys.allCases.map { .rowField(row: "spark", field: $0.stringValue) }
        features += CardTable.CodingKeys.allCases.map { .rowField(row: "table", field: $0.stringValue) }
        features += CardTableColumn.CodingKeys.allCases.map { .rowField(row: "table.columns", field: $0.stringValue) }
        features += CanvasRow.CodingKeys.allCases.map { .rowField(row: "canvas", field: $0.stringValue) }
        features += CardIcon.allCases.map { .listIcon($0.rawValue) }
        features += CardTableColumn.Alignment.allCases.map { .tableAlignment($0.rawValue) }
        features += CardAction.CodingKeys.allCases.map { .actionField($0.stringValue) }
        return features
    }

    @Test("every part of the contract the code reads has the release it came in")
    func everythingIsRegistered() {
        let missing = Self.fromTheCode.filter { ContractFeatures.release(of: $0) == nil }
        #expect(missing.isEmpty, "not in ContractFeatures.registry: \(missing)")
        #expect(Self.fromTheCode.count > 90)
    }

    /// And nothing is in the registry that the code does not read: a part of
    /// the contract that went away would otherwise keep a date nobody checks.
    @Test("the registry holds nothing the code does not read")
    func nothingStale() {
        let known = Set(Self.fromTheCode)
        let stale = ContractFeatures.registry.keys.filter {
            switch $0 {
            case .environment, .actionEnvironment: return false // the app's tests hold these
            default: return !known.contains($0)
            }
        }
        #expect(stale.isEmpty, "\(stale)")
    }

    /// `restart` is decoded by uDeck and described by no part of the contract
    /// (docs/plugin-api.md): the strict check calls it rule 12, and the
    /// registry dates it only when the contract takes it in.
    @Test("restart is read by uDeck's decoder and is no part of the contract")
    func restartIsOutside() {
        #expect(ContractFeatures.outsideTheContract == ["restart"])
        #expect(PluginManifest.CodingKeys.allCases.map(\.stringValue).contains("restart"))
        #expect(ContractFeatures.release(of: .manifestField("restart")) == nil)
    }

    /// At a release, `.next` becomes the release's number and `reviewedAt`
    /// its version; this fails until both are done.
    @Test("the registry was brought up to date for this release")
    func reviewedForThisRelease() throws {
        #expect(ContractFeatures.reviewedAt == UDeckRelease.version,
                "UDeckRelease.version moved: turn every .next into .released(\(UDeckRelease.version)) and move reviewedAt")
        let current = try #require(SemanticVersion(UDeckRelease.version))
        for (feature, release) in ContractFeatures.registry {
            if case .released(let version) = release { #expect(version <= current, "\(feature) is dated after this release") }
        }
    }

    /// Measured with git for every release tag: all of it was in v0.1.0,
    /// except `minUDeck`, which no release has had yet.
    @Test("what the registry says now: v0.1.0 for everything, and minUDeck not released")
    func whatItSaysNow() {
        let first = ContractRelease.released(SemanticVersion(major: 0, minor: 1, patch: 0))
        for (feature, release) in ContractFeatures.registry where feature != .manifestField("minUDeck") {
            #expect(release == first, "\(feature)")
        }
        #expect(ContractFeatures.minimumUDeckReadFrom == .next)
        #expect(ContractRelease.released(SemanticVersion(major: 99, minor: 0, patch: 0)) < .next)
        #expect(ContractRelease.next.isMet(by: SemanticVersion(major: 0, minor: 5, patch: 1)) == (UDeckRelease.version == "0.5.0"))
        #expect(!ContractRelease.next.isMet(by: SemanticVersion(UDeckRelease.version)!))
    }

    // MARK: - What a manifest uses

    func object(_ text: String) throws -> StrictJSON.Object {
        try #require(StrictJSON.parse(Array(text.utf8)).value?.object, "\(text)")
    }

    @Test("a manifest uses the fields it gives, the types its settings have, and its translations")
    func used() throws {
        let manifest = try object("""
            {"id": "x", "kind": "poll", "minUDeck": "0.6.0", "homepage": null, "made-up": 1,
             "permissions": {"exec": ["df"], "screen": null},
             "settings": [{"key": "k", "type": "enum", "options": [{"value": "a", "label": "A"}]}],
             "window": {"minWidth": 2}, "restart": {"mode": "never"}}
            """)
        // `restart` is decoded and outside the contract: nothing of it is used.
        let used = ContractFeatures.used(by: manifest, translations: [try object(#"{"name": "X", "settings": {"k": {"help": "h"}}}"#)])
        #expect(used == [
            .manifestField("id"), .manifestField("kind"), .manifestField("permissions"), .manifestField("settings"),
            .manifestField("window"), .pluginKind("poll"), .permission("exec"),
            .settingField("key"), .settingField("type"), .settingField("options"), .settingType("enum"),
            .optionField("value"), .optionField("label"), .windowField("minWidth"),
            .translations, .translationField("name"), .translationField("settings"),
            .settingTranslationField("help"),
        ])
        #expect(ContractFeatures.used(by: manifest, translations: []).contains(.translations) == false)
    }

    // MARK: - Rule 19

    func rule19(_ manifest: String, registry: [ContractFeature: ContractRelease] = ContractFeatures.registry) throws -> [CheckFinding] {
        var report = CheckReport()
        ContractFeatures.checkMinimumUDeck(try object(manifest), translations: [], path: "m.json", registry: registry,
                                           report: &report)
        return report.findings
    }

    /// With the registry as it is, no plugin needs `minUDeck`. One that
    /// declares a release up to the first that could read the field is told it
    /// does nothing; one that declares a later release is left alone — the
    /// author may know of a change in how uDeck behaves that no part of the
    /// contract names.
    @Test("minUDeck is said to do nothing only when no uDeck that reads it could miss it")
    func doesNothing() throws {
        #expect(try rule19(#"{"id": "x", "kind": "poll"}"#).isEmpty)
        #expect(try rule19(#"{"id": "x", "minUDeck": null}"#).isEmpty)
        let current = try #require(SemanticVersion(UDeckRelease.version))
        let first = current.next
        for declared in ["0.1.0", "\(current)", "\(first)"] {
            let findings = try rule19(#"{"id": "x", "kind": "poll", "minUDeck": "\#(declared)"}"#)
            #expect(findings.map(\.level) == [.warning], "\(declared)")
            #expect(findings.first?.rule == CheckRule.minimumUDeck)
            #expect(findings.first?.message.contains("does nothing") == true)
        }
        // Past the smallest number the next release can have, it may be above
        // it — and then it keeps every uDeck before it out, as the author meant.
        for declared in ["\(first.next)", "0.6.0", "99.0.0"] {
            #expect(try rule19(#"{"id": "x", "kind": "poll", "minUDeck": "\#(declared)"}"#).isEmpty, "\(declared)")
        }
        #expect(try rule19(#"{"id": "x", "minUDeck": "0.1"}"#).isEmpty, "not a version: rule 4 says so")
        #expect(try rule19(#"{"id": "x", "minUDeck": 5}"#).isEmpty, "not text: rule 3 says so")
    }

    /// Once the release that reads `minUDeck` has its number, the line is
    /// that number: at it or below, the field does nothing; above, the
    /// author's choice.
    @Test("with minUDeck's release named, it does nothing up to that release and is the author's above it")
    func doesNothingUpToItsRelease() throws {
        var registry = ContractFeatures.registry
        registry[.manifestField("minUDeck")] = .released(SemanticVersion(major: 0, minor: 6, patch: 0))
        for declared in ["0.5.9", "0.6.0"] {
            #expect(try rule19(#"{"id": "x", "minUDeck": "\#(declared)"}"#, registry: registry).map(\.level) == [.warning],
                    "\(declared)")
        }
        for declared in ["0.6.1", "1.0.0"] {
            #expect(try rule19(#"{"id": "x", "minUDeck": "\#(declared)"}"#, registry: registry).isEmpty, "\(declared)")
        }
    }

    /// A registry with a newer part in it — what the next release will bring
    /// the first time the contract grows.
    static let grown: [ContractFeature: ContractRelease] = {
        var registry = ContractFeatures.registry
        registry[.settingType("enum")] = .released(SemanticVersion(major: 0, minor: 8, patch: 0))
        registry[.manifestField("minUDeck")] = .released(SemanticVersion(major: 0, minor: 6, patch: 0))
        return registry
    }()

    static let usesEnum = #"{"id": "x", "settings": [{"key": "k", "type": "enum"}]"#

    @Test("a declared minUDeck below what the plugin uses is an error, and naming it is enough")
    func belowWhatItUses() throws {
        let below = try rule19(Self.usesEnum + #", "minUDeck": "0.7.9"}"#, registry: Self.grown)
        #expect(below.map(\.level) == [.error])
        #expect(below.first?.message.contains("uDeck 0.8.0") == true)
        #expect(below.first?.message.contains("setting type \"enum\"") == true)
        #expect(try rule19(Self.usesEnum + #", "minUDeck": "0.8.0"}"#, registry: Self.grown).isEmpty)
        #expect(try rule19(Self.usesEnum + #", "minUDeck": "1.0.0"}"#, registry: Self.grown).isEmpty)
        // Left out, it lets every uDeck that reads it install the plugin.
        let absent = try rule19(Self.usesEnum + "}", registry: Self.grown)
        #expect(absent.map(\.level) == [.error])
        #expect(absent.first?.message.contains("no \"minUDeck\"") == true)
        // What came before the first uDeck that reads minUDeck needs nothing.
        #expect(try rule19(#"{"id": "x", "settings": [{"key": "k", "type": "int"}]}"#, registry: Self.grown).isEmpty)
    }

    @Test("a part not released yet is met only by a uDeck after this one")
    func unreleased() throws {
        // As if an earlier release had read minUDeck already, so that a
        // declared version after this one is not one that does nothing.
        var registry = Self.grown
        registry[.manifestField("minUDeck")] = .released(SemanticVersion(major: 0, minor: 3, patch: 0))
        registry[.settingType("enum")] = .next
        #expect(try rule19(Self.usesEnum + #", "minUDeck": "\#(UDeckRelease.version)"}"#, registry: registry).map(\.level) == [.error])
        let after = SemanticVersion(UDeckRelease.version).map { SemanticVersion(major: $0.major, minor: $0.minor, patch: $0.patch + 1) }!
        #expect(try rule19(Self.usesEnum + #", "minUDeck": "\#(after)"}"#, registry: registry).isEmpty)
    }
}
