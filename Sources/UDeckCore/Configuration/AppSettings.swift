import CoreGraphics
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

    /// The keyboard way in. The pointer is the primary one; this is for when
    /// the cursor is nowhere near the top of the screen.
    public var hotkey: HotKeyBinding

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

    /// Keep polling producers while the panel is out of sight.
    ///
    /// Off by default. A panel nobody is looking at that still runs a dozen
    /// scripts every few seconds is a laptop that runs out of battery for no
    /// reason. Revealing the panel refreshes everything immediately, and the
    /// staleness rules make the gap between "last known" and "current" visible
    /// while that happens — so the cost of being off is a moment of honestly
    /// labelled old data rather than a wrong answer.
    public var pollWhileCollapsed: Bool

    public init(
        version: Int = 1,
        density: Density = .normal,
        gesture: GestureTuning = GestureTuning(),
        panel: PanelMetrics = PanelMetrics(),
        hotkey: HotKeyBinding = HotKeyBinding(),
        collapseOnAppSwitch: Bool = true,
        defaultCardTTL: TimeInterval = 60,
        silentTTLMultiplier: Double = 3,
        pluginExecutableSearchPath: [String] = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ],
        pollWhileCollapsed: Bool = false
    ) {
        self.version = version
        self.density = density
        self.gesture = gesture
        self.panel = panel
        self.hotkey = hotkey
        self.collapseOnAppSwitch = collapseOnAppSwitch
        self.defaultCardTTL = defaultCardTTL
        self.silentTTLMultiplier = silentTTLMultiplier
        self.pluginExecutableSearchPath = pluginExecutableSearchPath
        self.pollWhileCollapsed = pollWhileCollapsed
    }

    /// Brings decoded settings into ranges that make sense.
    ///
    /// A plugin's manifest is validated carefully and the operator's own
    /// settings file was not, which is the wrong way round: the manifest comes
    /// from someone who reads the documentation, and this file is edited by
    /// hand at two in the morning. A poll interval of `0.0001` or a negative
    /// grace period should not be obeyed literally.
    public func validated() -> AppSettings {
        var result = self
        func clamp(_ value: TimeInterval, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
            guard value.isFinite else { return range.lowerBound }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
            guard value.isFinite else { return range.lowerBound }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        result.gesture.stripHeight = clamp(result.gesture.stripHeight, 1 ... 200)
        result.gesture.stripSideMargin = clamp(result.gesture.stripSideMargin, 0 ... 2000)
        result.gesture.virtualAnchorWidth = clamp(result.gesture.virtualAnchorWidth, 20 ... 2000)
        result.gesture.pinnedEpsilon = clamp(result.gesture.pinnedEpsilon, 0 ... 50)
        result.gesture.edgePushDistance = clamp(result.gesture.edgePushDistance, 1 ... 2000)
        result.gesture.edgePushWindow = clamp(result.gesture.edgePushWindow, 0.02 ... 5)
        result.gesture.dwellDuration = clamp(result.gesture.dwellDuration, 0.02 ... 5)
        result.gesture.lateralApproachDwellDuration = clamp(result.gesture.lateralApproachDwellDuration, 0.02 ... 10)
        result.gesture.dwellHorizontalTolerance = clamp(result.gesture.dwellHorizontalTolerance, 1 ... 500)
        result.gesture.dwellHorizontalSpeedLimit = clamp(result.gesture.dwellHorizontalSpeedLimit, 10 ... 10_000)
        result.gesture.approachSampleDistance = clamp(result.gesture.approachSampleDistance, 10 ... 5000)
        result.gesture.lateralApproachRatio = clamp(result.gesture.lateralApproachRatio, 0.1 ... 50)
        result.gesture.reopenCooldown = clamp(result.gesture.reopenCooldown, 0 ... 30)
        result.gesture.buttonReleaseGrace = clamp(result.gesture.buttonReleaseGrace, 0 ... 30)
        result.gesture.peekExitGrace = clamp(result.gesture.peekExitGrace, 0.02 ... 30)
        result.gesture.peekKeepAliveInset = clamp(result.gesture.peekKeepAliveInset, 0 ... 500)
        result.gesture.fullscreenCheckInterval = clamp(result.gesture.fullscreenCheckInterval, 0.05 ... 60)
        // Zero is meaningful here — it turns the safety poll off — so it is the
        // only value below the floor that survives.
        if result.gesture.pointerPollInterval != 0 {
            result.gesture.pointerPollInterval = clamp(result.gesture.pointerPollInterval, 0.02 ... 5)
        }

        result.panel.pillHeight = clamp(result.panel.pillHeight, 1 ... 200)
        result.panel.pillWidthFactor = clamp(result.panel.pillWidthFactor, 0.05 ... 1)
        result.panel.peekWidthFraction = clamp(result.panel.peekWidthFraction, 0.05 ... 1)
        result.panel.peekMaxWidth = clamp(result.panel.peekMaxWidth, 100 ... 10_000)
        result.panel.peekHeight = clamp(result.panel.peekHeight, 20 ... 5000)
        result.panel.openWidthFraction = clamp(result.panel.openWidthFraction, 0.05 ... 1)
        result.panel.openMaxWidth = clamp(result.panel.openMaxWidth, 100 ... 10_000)
        result.panel.openHeightFraction = clamp(result.panel.openHeightFraction, 0.05 ... 1)
        result.panel.openMaxHeight = clamp(result.panel.openMaxHeight, 60 ... 10_000)
        result.panel.cornerRadius = clamp(result.panel.cornerRadius, 0 ... 100)
        result.panel.islandCornerRadius = clamp(result.panel.islandCornerRadius, 0 ... 100)
        result.panel.topEdgeBleed = clamp(result.panel.topEdgeBleed, 0 ... 50)
        result.panel.revealDuration = clamp(result.panel.revealDuration, 0 ... 3)

        // A shortcut that cannot be registered is turned off rather than left
        // enabled-and-broken: "on, and nothing happens when you press it" is
        // the state that costs an evening to diagnose. What made it invalid is
        // kept as written so the settings screen can show what was meant.
        if result.hotkey.enabled, !result.hotkey.isValid {
            result.hotkey.enabled = false
        }

        result.defaultCardTTL = clamp(result.defaultCardTTL, 1 ... Seconds.ceiling)
        result.silentTTLMultiplier = min(max(result.silentTTLMultiplier.isFinite ? result.silentTTLMultiplier : 3, 1), 100)
        if result.pluginExecutableSearchPath.isEmpty {
            result.pluginExecutableSearchPath = AppSettings().pluginExecutableSearchPath
        }
        return result
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
        hotkey = try c.decodeIfPresent(HotKeyBinding.self, forKey: .hotkey) ?? defaults.hotkey
        collapseOnAppSwitch = try c.decodeIfPresent(Bool.self, forKey: .collapseOnAppSwitch)
            ?? defaults.collapseOnAppSwitch
        defaultCardTTL = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultCardTTL)
            ?? defaults.defaultCardTTL
        silentTTLMultiplier = try c.decodeIfPresent(Double.self, forKey: .silentTTLMultiplier)
            ?? defaults.silentTTLMultiplier
        pluginExecutableSearchPath = try c.decodeIfPresent([String].self, forKey: .pluginExecutableSearchPath)
            ?? defaults.pluginExecutableSearchPath
        pollWhileCollapsed = try c.decodeIfPresent(Bool.self, forKey: .pollWhileCollapsed)
            ?? defaults.pollWhileCollapsed
    }
}
