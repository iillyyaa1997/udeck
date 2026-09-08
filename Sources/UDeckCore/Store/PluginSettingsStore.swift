import Foundation

/// The values the operator has chosen for the settings plugins declare.
///
/// Kept apart from the app's own settings because the two have different
/// lifetimes: uninstalling a plugin should take its values with it, and a
/// plugin's settings should survive an upgrade of uDeck itself.
public struct PluginSettings: Codable, Equatable, Sendable {
    public var version: Int

    /// plugin id -> setting key -> value.
    public var values: [String: [String: SettingValue]]

    /// Which plugins the operator has switched off. Absent means enabled: a new
    /// plugin should work the moment it is installed and permitted.
    public var disabled: Set<String>

    public init(version: Int = 1,
                values: [String: [String: SettingValue]] = [:],
                disabled: Set<String> = []) {
        self.version = version
        self.values = values
        self.disabled = disabled
    }

    public func isEnabled(_ id: PluginIdentifier) -> Bool { !disabled.contains(id.rawValue) }

    public mutating func setEnabled(_ enabled: Bool, for id: PluginIdentifier) {
        if enabled { disabled.remove(id.rawValue) } else { disabled.insert(id.rawValue) }
    }

    /// The effective value of one setting: what the operator chose, brought
    /// back into the range the current manifest declares, or the default.
    public func value(of declaration: SettingDeclaration, for id: PluginIdentifier) -> SettingValue {
        guard let stored = values[id.rawValue]?[declaration.key] else { return declaration.defaultValue }
        return declaration.coerce(stored)
    }

    public mutating func set(_ value: SettingValue, for key: String, plugin id: PluginIdentifier) {
        values[id.rawValue, default: [:]][key] = value
    }

    public mutating func forget(_ id: PluginIdentifier) {
        values.removeValue(forKey: id.rawValue)
        disabled.remove(id.rawValue)
    }

    /// The environment a plugin's process receives for its settings.
    public func environment(for manifest: PluginManifest) -> [String: String] {
        var env: [String: String] = [:]
        for declaration in manifest.settings {
            let value = value(of: declaration, for: manifest.id)
            env[PluginIdentifier.settingEnvironmentKey(declaration.key)] = value.jsonLiteral
        }
        return env
    }
}
