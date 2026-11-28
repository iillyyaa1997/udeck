#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A plugin's manifest, said in another language.
///
/// Shipped as `manifest.<code>.json` beside `manifest.json` — `manifest.ru.json`,
/// `manifest.de.json` — one file per language, any number of them. A translator
/// can send the author a file rather than a diff against the file the plugin is
/// defined by, and a language the plugin gains costs nothing anybody has to
/// merge.
///
/// **It holds strings and nothing else, and that is the point.** There is no
/// `run` here, no `permissions`, no `id` — not omitted, but absent from the
/// type, so no translation can carry them however it is written. A file that
/// could add a command or a capability would be a way to put behaviour past the
/// consent the operator already gave: he read what the plugin asked for and
/// agreed to that, and a translation arriving later must not be able to change
/// what he agreed to. Everything uDeck acts on keeps coming from `manifest.json`.
///
/// Every field is optional and falls back to the base manifest, so a half-done
/// translation shows the parts that are done rather than blanks.
public struct ManifestTranslation: Codable, Equatable, Sendable {
    public var name: String?
    public var description: String?

    /// Keyed by the setting's `key`, as declared in `manifest.json`. A key that
    /// is not declared there is ignored: a translation cannot bring a setting
    /// into existence, only rename one that is already there.
    public var settings: [String: SettingTranslation]?

    /// Keyed by the group's `id`: its label in this language (0.9.32).
    public var settingGroups: [String: SettingGroupTranslation]?

    public init(
        name: String? = nil,
        description: String? = nil,
        settings: [String: SettingTranslation]? = nil,
        settingGroups: [String: SettingGroupTranslation]? = nil
    ) {
        self.name = name
        self.description = description
        self.settings = settings
        self.settingGroups = settingGroups
    }

    /// See `GlassAppearance.init(from:)` — the same tolerance, for the same
    /// reason. One misspelt field should cost the field, not the translation.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            settings: try c.decodeIfPresent([String: SettingTranslation].self, forKey: .settings),
            settingGroups: try? c.decodeIfPresent([String: SettingGroupTranslation].self, forKey: .settingGroups)
        )
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case description
        case settings
        case settingGroups
    }
}

/// A setting group's label in another language.
public struct SettingGroupTranslation: Codable, Equatable, Sendable {
    public var label: String?

    public init(label: String? = nil) { self.label = label }

    enum CodingKeys: String, CodingKey, CaseIterable { case label }
}

/// One declared setting, said in another language.
public struct SettingTranslation: Codable, Equatable, Sendable {
    public var label: String?
    public var help: String?
    /// The heading the setting starts under (0.9.32).
    public var section: String?

    /// Keyed by the option's `value`, which is what the setting is stored as and
    /// therefore the one part of an option that must not be translated.
    public var options: [String: String]?

    public init(label: String? = nil, help: String? = nil, options: [String: String]? = nil, section: String? = nil) {
        self.label = label
        self.help = help
        self.options = options
        self.section = section
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try c.decodeIfPresent(String.self, forKey: .label),
            help: try c.decodeIfPresent(String.self, forKey: .help),
            options: try c.decodeIfPresent([String: String].self, forKey: .options),
            section: try? c.decodeIfPresent(String.self, forKey: .section)
        )
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case label
        case help
        case options
        case section
    }
}

public extension PluginManifest {
    /// This manifest with its display strings replaced, and nothing else touched.
    ///
    /// Written as an explicit field-by-field assignment rather than a merge, so
    /// that what a translation can reach is legible here and stays that way: the
    /// name, the description, and the label, help and option names of settings
    /// that already exist.
    func applying(_ translation: ManifestTranslation) -> PluginManifest {
        var result = self
        if let name = translation.name, !name.isEmpty { result.name = name }
        if let description = translation.description, !description.isEmpty {
            result.description = description
        }
        if let groups = translation.settingGroups, !groups.isEmpty {
            result.settingGroups = settingGroups.map { group in
                guard let label = groups[group.id]?.label, !label.isEmpty else { return group }
                var group = group
                group.label = label
                return group
            }
        }
        guard let translated = translation.settings, !translated.isEmpty else { return result }

        result.settings = settings.map { declaration in
            guard let t = translated[declaration.key] else { return declaration }
            var declaration = declaration
            if let label = t.label, !label.isEmpty { declaration.label = label }
            if let help = t.help, !help.isEmpty { declaration.help = help }
            if let section = t.section, !section.isEmpty, declaration.section != nil { declaration.section = section }
            if let names = t.options, let options = declaration.options {
                declaration.options = options.map { option in
                    guard let label = names[option.value], !label.isEmpty else { return option }
                    // The value is what the setting is stored as, and is never
                    // translated — only the label the operator reads.
                    return SettingOption(value: option.value, label: label)
                }
            }
            return declaration
        }
        return result
    }
}
