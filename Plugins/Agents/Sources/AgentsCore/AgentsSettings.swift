import Foundation
import UDeckAgents

/// Agents' settings: as uDeck started the plugin with them (`UDECK_SETTING_*`,
/// each value JSON), then as the `settings` event says while it runs (uDeck
/// 0.9.32) — changed in Settings, seen at once, the plugin not restarted.
public struct AgentsSettings: Sendable, Equatable {
    private(set) var values: [String: JSONValue] = [:]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// From the environment uDeck built: `UDECK_SETTING_KEEP_AWAKE=true`.
    public init(environment: [String: String]) {
        for (name, raw) in environment where name.hasPrefix("UDECK_SETTING_") {
            let key = name.dropFirst("UDECK_SETTING_".count).lowercased()
            values[key] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
        }
    }

    /// What a `settings` event says: every setting, as it is now.
    public mutating func update(_ settings: JSONValue?) {
        for (key, value) in settings?.object ?? [:] { values[key] = value }
    }

    public func bool(_ key: String, _ fallback: Bool) -> Bool { values[key]?.bool ?? fallback }
    public func string(_ key: String, _ fallback: String) -> String { values[key]?.string ?? fallback }
    public func int(_ key: String, _ fallback: Int) -> Int { values[key]?.int ?? fallback }

    /// How the context is shown, defaults the operator's own set (11-28).
    public var context: ContextLook {
        ContextLook(badge: string("ctx_badge", "tokens"), tone: bool("ctx_tone", true),
                    details: string("ctx_details", "click"),
                    parts: bool("ctx_parts", true), graph: bool("ctx_graph", true), turns: bool("ctx_turns", true),
                    heavy: bool("ctx_heavy", true), cache: bool("ctx_cache", true), week: bool("ctx_week", true),
                    cost: bool("ctx_cost", true), model: bool("ctx_model", true), account: bool("ctx_account", true),
                    auto: bool("ctx_auto", true),
                    compactNow: bool("ctx_btn_compact", true), compactHint: bool("ctx_btn_hint", true),
                    fresh: bool("ctx_btn_fresh", true),
                    pause: bool("ctx_pause", true), pauseAt: min(95, max(40, int("ctx_pause_at", 70))),
                    mark: bool("ctx_mark", true))
    }

    /// How the Mac kept awake is said: `icon`, `one`, `two` or `none`.
    public var sleepShown: String { string("sleep_show", "icon") }
}

/// What of the context the card shows, and how.
public struct ContextLook: Sendable, Equatable {
    /// `percent`, `tokens`, `pie`, `strip` or `none`.
    public var badge: String
    public var tone: Bool
    /// `click`, `line` or `off`.
    public var details: String
    public var parts: Bool
    public var graph: Bool
    public var turns: Bool
    public var heavy: Bool
    public var cache: Bool
    public var week: Bool
    public var cost: Bool
    public var model: Bool
    public var account: Bool
    public var auto: Bool
    public var compactNow: Bool
    public var compactHint: Bool
    public var fresh: Bool
    public var pause: Bool
    public var pauseAt: Int
    public var mark: Bool

    public static let standard = AgentsSettings().context
}
