import Foundation

/// Everything the operator can configure about the shell itself.
///
/// Plugin-declared settings are stored separately, keyed by plugin id — see
/// `PluginSettingsStore` — because they have a different lifetime: uninstalling
/// a plugin should not leave its values in the app's own settings file.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Schema version of this file. Bumped only when a migration is needed.
    public var version: Int

    public var density: Density
    public var gesture: GestureTuning
    public var panel: PanelMetrics

    /// Retract the panel when the operator activates another application.
    public var collapseOnAppSwitch: Bool

    /// Default lifetime applied to a card whose producer did not declare a
    /// `ttl`. Kept generous: a producer that forgot to declare one should not
    /// be accused of being broken a few seconds later.
    public var defaultCardTTL: TimeInterval

    /// Multiple of a card's ttl past which the card stops showing its values at
    /// all and renders as `unknown`. Between 1x and this, values are still shown
    /// but visibly marked stale.
    public var silentTTLMultiplier: Double

    /// Where a plugin's `run[0]` is looked up when it is a bare command name
    /// rather than a path. Explicit rather than inherited from the launching
    /// shell: uDeck can be started from Finder, from a terminal or by launchd,
    /// and a plugin that works from one and not the others is a bug that is
    /// very hard to see.
    public var pluginExecutableSearchPath: [String]

    public init(
        version: Int = 1,
        density: Density = .normal,
        gesture: GestureTuning = GestureTuning(),
        panel: PanelMetrics = PanelMetrics(),
        collapseOnAppSwitch: Bool = true,
        defaultCardTTL: TimeInterval = 60,
        silentTTLMultiplier: Double = 3,
        pluginExecutableSearchPath: [String] = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    ) {
        self.version = version
        self.density = density
        self.gesture = gesture
        self.panel = panel
        self.collapseOnAppSwitch = collapseOnAppSwitch
        self.defaultCardTTL = defaultCardTTL
        self.silentTTLMultiplier = silentTTLMultiplier
        self.pluginExecutableSearchPath = pluginExecutableSearchPath
    }

    /// Decoding is tolerant of missing keys so that a settings file written by
    /// an older build still loads, and of unknown keys so that downgrading does
    /// not destroy them — but it is NOT tolerant of a wrong type, which is a
    /// real error the operator needs to see.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? defaults.density
        gesture = try c.decodeIfPresent(GestureTuning.self, forKey: .gesture) ?? defaults.gesture
        panel = try c.decodeIfPresent(PanelMetrics.self, forKey: .panel) ?? defaults.panel
        collapseOnAppSwitch = try c.decodeIfPresent(Bool.self, forKey: .collapseOnAppSwitch)
            ?? defaults.collapseOnAppSwitch
        defaultCardTTL = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultCardTTL)
            ?? defaults.defaultCardTTL
        silentTTLMultiplier = try c.decodeIfPresent(Double.self, forKey: .silentTTLMultiplier)
            ?? defaults.silentTTLMultiplier
        pluginExecutableSearchPath = try c.decodeIfPresent([String].self, forKey: .pluginExecutableSearchPath)
            ?? defaults.pluginExecutableSearchPath
    }
}
