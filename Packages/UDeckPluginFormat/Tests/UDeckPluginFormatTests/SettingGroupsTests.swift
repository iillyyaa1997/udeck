import Foundation
import Testing
@testable import UDeckPluginFormat

/// A plugin's settings in groups, each a tab of Settings, one of them with a
/// card the plugin draws beside it (0.9.32) — the operator's page of
/// switches with the card that follows them, asked for in Settings (11-28).
@Suite("Settings in groups, with a preview")
struct SettingGroupsTests {
    let manifest = """
    { "id": "agents", "name": "Agents", "version": "1.0.0", "api": 1, "kind": "resident", "run": ["./agents"],
      "settingGroups": [ { "id": "context", "label": "Context", "preview": true }, { "id": "sleep", "label": "Sleep" } ],
      "settings": [
        { "key": "editor", "type": "string", "label": "Editor", "default": "" },
        { "key": "badge", "type": "enum", "label": "Badge", "default": "tokens", "group": "context", "section": "The badge",
          "options": [ { "value": "percent", "label": "Percent" }, { "value": "tokens", "label": "Percent and tokens" } ] },
        { "key": "pause_at", "type": "int", "label": "Compact in the pause at", "default": 70, "min": 40, "max": 95,
          "group": "context", "section": "Compaction" },
        { "key": "coffee", "type": "bool", "label": "A cup for sleep", "default": true, "group": "sleep" }
      ] }
    """

    func decode(_ text: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(text.utf8))
    }

    @Test("groups, a group's preview, and the group and heading of each setting are read")
    func read() throws {
        let manifest = try decode(manifest)
        #expect(manifest.settingGroups.map(\.id) == ["context", "sleep"])
        #expect(manifest.settingGroups.map(\.hasPreview) == [true, false])
        #expect(manifest.settings.map(\.group) == [nil, "context", "context", "sleep"])
        #expect(manifest.settings.map(\.section) == [nil, "The badge", "Compaction", nil])
        #expect(manifest.problems().isEmpty, "\(manifest.problems())")
        // None declared: as before, every setting in one place.
        let plain = try decode(#"{"id":"p","name":"P","version":"1.0.0","api":1,"kind":"poll","run":["./p"],"interval":60}"#)
        #expect(plain.settingGroups.isEmpty)
    }

    @Test("a group not declared, two groups with one id, a blank label and more than eight are problems")
    func problems() throws {
        var manifest = try decode(manifest)
        manifest.settings[3].group = "nowhere"
        #expect(manifest.problems().contains(.invalidSettingDeclaration(key: "coffee",
                                                                        reason: "group \"nowhere\" is not one of settingGroups")))
        manifest = try decode(self.manifest)
        manifest.settingGroups.append(SettingGroup(id: "context", label: "Again"))
        #expect(manifest.problems().contains(.invalidSettingGroup(id: "context", reason: "two groups share this id")))
        manifest = try decode(self.manifest)
        manifest.settingGroups[1].label = " "
        #expect(manifest.problems().contains(.invalidSettingGroup(id: "sleep", reason: "label must not be blank")))
        manifest.settingGroups[1] = SettingGroup(id: "Sleep!", label: "Sleep")
        #expect(manifest.problems().contains(.invalidSettingGroup(id: "Sleep!",
                                                                  reason: "id must be lowercase letters, digits and underscores")))
        manifest = try decode(self.manifest)
        manifest.settingGroups = (0 ... SettingGroup.limit).map { SettingGroup(id: "g\($0)", label: "G\($0)") }
        manifest.settings = manifest.settings.map { var setting = $0; setting.group = nil; return setting }
        #expect(manifest.problems().contains(.invalidSettingGroup(id: "g\(SettingGroup.limit)",
                                                                  reason: "more than \(SettingGroup.limit) groups")))
    }

    @Test("a translation names the groups and the headings, and nothing else of them")
    func translated() throws {
        let russian = try JSONDecoder().decode(ManifestTranslation.self, from: Data("""
            { "settingGroups": { "context": { "label": "Контекст" }, "nowhere": { "label": "Нигде" } },
              "settings": { "badge": { "section": "Значок" }, "coffee": { "section": "Не бывает" } } }
            """.utf8))
        let manifest = try decode(manifest).applying(russian)
        #expect(manifest.settingGroups.map(\.label) == ["Контекст", "Sleep"])
        #expect(manifest.settingGroups.map(\.id) == ["context", "sleep"], "the id is what settings are stored by")
        #expect(manifest.settingGroups.map(\.hasPreview) == [true, false])
        #expect(manifest.settings.map(\.section) == [nil, "Значок", "Compaction", nil],
                "a heading is translated where the manifest has one, never brought in")
    }

    @Test("the shape check reads the new fields and names a typo in them")
    func shape() throws {
        let typo = """
        { "id": "agents", "name": "Agents", "version": "1.0.0", "api": 1, "kind": "resident", "run": ["./agents"],
          "settingGroups": [ { "id": "context", "label": "Context", "preveiw": true }, { "id": 3, "label": "X" } ],
          "settings": [ { "key": "k", "type": "bool", "label": "K", "default": true, "group": 1 } ] }
        """
        let value = try #require(StrictJSON.parse(Array(typo.utf8)).value)
        let object = try #require(value.object)
        #expect(ManifestShape.unknownFields(of: object).contains("settingGroups[0].preveiw"))
        let problems = ManifestShape.problems(of: value)
        #expect(problems.contains { $0.contains("settingGroups[1].id") }, "\(problems)")
        #expect(problems.contains { $0.contains("settings[0].group") }, "\(problems)")
        let good = try #require(StrictJSON.parse(Array(manifest.utf8)).value)
        #expect(ManifestShape.problems(of: good).isEmpty, "\(ManifestShape.problems(of: good))")
        #expect(ManifestShape.unknownFields(of: try #require(good.object)).isEmpty)
        let translation = try #require(StrictJSON.parse(Array(#"{"settingGroups": {"context": {"label": "К", "lable": "x"}, "gone": {"label": "Y"}}}"#.utf8)).value)
        let said = ManifestShape.translationProblems(of: translation, manifest: try decode(manifest))
        #expect(said.contains { $0.contains("settingGroups.context.lable") }, "\(said)")
        #expect(said.contains { $0.contains("\"gone\"") }, "\(said)")
    }

    @Test("what a manifest uses of the new fields is dated, for the repository check")
    func used() throws {
        let object = try #require(StrictJSON.parse(Array(manifest.utf8)).value?.object)
        let used = ContractFeatures.used(by: object, translations: [])
        for feature: ContractFeature in [.manifestField("settingGroups"), .settingGroupField("id"), .settingGroupField("label"),
                                         .settingGroupField("preview"), .settingField("group"), .settingField("section")] {
            #expect(used.contains(feature), "\(feature)")
        }
    }

    @Test("the settings event says every value as JSON, the preview event its group, and a preview answers with a card")
    func protocolLines() throws {
        let settings = ResidentEvent.settings(["badge": .string("tokens"), "pause_at": .int(70), "coffee": .bool(true)]).line
        let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect(object["event"] as? String == "settings")
        let values = try #require(object["settings"] as? [String: Any])
        #expect(values["badge"] as? String == "tokens")
        #expect(values["pause_at"] as? Int == 70)
        #expect(values["coffee"] as? Bool == true)
        #expect(ResidentEvent.preview(group: "context").line == #"{"event":"preview","id":"context"}"#)

        let answer = ResidentMessage(line: #"{"preview":{"group":"context","card":{"title":"Sample","rows":[]}}}"#)
        guard case .preview(let group, let card) = answer else {
            Issue.record("not a preview: \(answer)")
            return
        }
        #expect(group == "context")
        #expect(card.title == "Sample")
        #expect(ResidentMessage(line: #"{"preview":{"card":{"rows":[]}}}"#) == .unknown(#"{"preview":{"card":{"rows":[]}}}"#),
                "a preview names its group")
    }
}
