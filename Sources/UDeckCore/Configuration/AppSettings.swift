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

    /// The two looks and what decides between them.
    ///
    /// This is the truth about how the panel is dressed. `glass` and `ink`
    /// below are what that truth resolves to right now — see `resolved`.
    public var theme: ThemeSettings

    /// The look currently in force, whole.
    ///
    /// **Derived.** Written by `resolved(systemIsDark:hour:)` from `theme`, and
    /// read by everything that draws. It is stored rather than computed because
    /// a settings file that names the resolved look is one a person can still
    /// read — but editing it directly is editing a cache: the next resolve
    /// overwrites it. The settings screen edits `theme.light` and `theme.dark`.
    public var look: PanelLook

    /// Which pole the look in force came from.
    ///
    /// **Derived**, like `look` itself and for the same reason: the states
    /// below keep their own values for each half of the day, so resolving one
    /// of them needs to know which half it is. Written by
    /// `resolved(systemIsDark:hour:)`; editing it by hand lasts until the next
    /// resolve.
    public var resolvedIsDark: Bool

    /// How the panel's glass is made, in the look currently in force.
    public var glass: GlassAppearance { look.glass }

    /// Which way the panel's text is written, in the look currently in force.
    public var ink: PanelInk { look.ink }

    /// How far the island fades back while it is away, and whether it does.
    public var quiet: IslandQuiet

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

    /// How big the panel's text is, in points, or `nil` for whatever the
    /// density asks for.
    ///
    /// Its own control rather than another step of `density`, because the two
    /// answer different questions: density is how much fits on the panel, and
    /// this is how big the lettering is. The operator wanted larger text at the
    /// spacing he already had, and three joint steps could not give him that —
    /// the top step was still small.
    ///
    /// Optional so that a settings file says nothing until he moves it, and so
    /// that the density keeps deciding for anyone who never does.
    public var textSize: CGFloat?

    /// The language uDeck speaks, or `nil` to follow the Mac.
    ///
    /// Optional rather than a third enum case, so that the settings file says
    /// nothing at all until the operator has chosen — which is what makes
    /// "follow the system" keep working for somebody who never opens this
    /// setting, and what lets uDeck start speaking a language it gains later
    /// without anyone editing a file.
    public var language: Language?

    public init(
        version: Int = 1,
        density: Density = .normal,
        gesture: GestureTuning = GestureTuning(),
        panel: PanelMetrics = PanelMetrics(),
        hotkey: HotKeyBinding = HotKeyBinding(),
        theme: ThemeSettings = ThemeSettings(),
        look: PanelLook = .light,
        resolvedIsDark: Bool = false,
        quiet: IslandQuiet = IslandQuiet(),
        collapseOnAppSwitch: Bool = true,
        defaultCardTTL: TimeInterval = 60,
        silentTTLMultiplier: Double = 3,
        pluginExecutableSearchPath: [String] = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ],
        pollWhileCollapsed: Bool = false,
        textSize: CGFloat? = nil,
        language: Language? = nil
    ) {
        self.version = version
        self.density = density
        self.gesture = gesture
        self.panel = panel
        self.hotkey = hotkey
        self.theme = theme
        self.look = look
        self.resolvedIsDark = resolvedIsDark
        self.quiet = quiet
        self.collapseOnAppSwitch = collapseOnAppSwitch
        self.defaultCardTTL = defaultCardTTL
        self.silentTTLMultiplier = silentTTLMultiplier
        self.pluginExecutableSearchPath = pluginExecutableSearchPath
        self.pollWhileCollapsed = pollWhileCollapsed
        self.textSize = textSize
        self.language = language
    }

    /// How big the text actually is.
    public var resolvedTextSize: CGFloat {
        guard let textSize, textSize.isFinite else { return density.bodyFontSize }
        return min(max(textSize, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
    }

    /// Small enough to be a glance, large enough to read across a room. Below
    /// ten the chip font — two points smaller again — stops being legible at
    /// all, which is the real floor.
    public static let textSizeRange: ClosedRange<CGFloat> = 10 ... 18

    /// The language actually in force.
    ///
    /// The Mac's own preference is handed in rather than read here, for the
    /// same reason `resolved(systemIsDark:hour:)` is handed the appearance:
    /// what the system is set to is the world's business, and a settings type
    /// that reaches out to ask cannot be tested without the world.
    public func resolvedLanguage(systemPreferred: Language) -> Language {
        language ?? systemPreferred
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

        result.theme = result.theme.validated()
        result.quiet.level = result.quiet.clampedLevel
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

        result.panel.peekWidthFraction = clamp(result.panel.peekWidthFraction, 0.05 ... 1)
        result.panel.peekMaxWidth = clamp(result.panel.peekMaxWidth, 100 ... 10_000)
        result.panel.peekHeight = clamp(result.panel.peekHeight, 20 ... 5000)
        result.panel.openWidthFraction = clamp(result.panel.openWidthFraction, 0.05 ... 1)
        result.panel.openMaxWidth = clamp(result.panel.openMaxWidth, 100 ... 10_000)
        result.panel.openHeightFraction = clamp(result.panel.openHeightFraction, 0.05 ... 1)
        result.panel.openMaxHeight = clamp(result.panel.openMaxHeight, 60 ... 10_000)
        result.panel.cornerRadius = clamp(result.panel.cornerRadius, 0 ... 100)
        result.panel.islandCornerRadius = clamp(result.panel.islandCornerRadius, 0 ... 100)
        result.panel.islandHeightFactor = clamp(result.panel.islandHeightFactor, 0.05 ... 1)
        result.panel.topEdgeBleed = clamp(result.panel.topEdgeBleed, 0 ... 50)
        result.panel.revealSpringResponse = clamp(result.panel.revealSpringResponse, 0.05 ... 3)
        result.panel.collapseDuration = clamp(result.panel.collapseDuration, 0 ... 3)
        result.panel.contentRevealDelay = clamp(result.panel.contentRevealDelay, 0 ... 3)
        result.panel.contentRevealDuration = clamp(result.panel.contentRevealDuration, 0.02 ... 3)
        result.panel.contentHideDuration = clamp(result.panel.contentHideDuration, 0.02 ... 3)
        // A damping fraction outside (0, 1] is not a slower spring, it is a
        // different equation; clamping keeps it a spring.
        result.panel.revealSpringDamping = min(max(
            result.panel.revealSpringDamping.isFinite ? result.panel.revealSpringDamping : 0.8, 0.1), 1)

        result.look = result.look.validated()

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

        /// What a settings file written before there was a `look` says instead.
        /// Read through a container of its own so that the keys the encoder
        /// uses stay exactly the properties there are — an extra case in the
        /// real `CodingKeys` is a case the synthesised encoder cannot fill.
        enum LegacyKeys: String, CodingKey {
            case glass
            case ink
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? defaults.density
        gesture = try c.decodeIfPresent(GestureTuning.self, forKey: .gesture) ?? defaults.gesture
        panel = try c.decodeIfPresent(PanelMetrics.self, forKey: .panel) ?? defaults.panel
        hotkey = try c.decodeIfPresent(HotKeyBinding.self, forKey: .hotkey) ?? defaults.hotkey
        // `look` names the resolved look; `glass` and `ink` beside it are what a
        // file written before there was a look says instead, and are read here
        // only so that such a file still carries its own appearance in.
        let carriedGlass = try legacy.decodeIfPresent(GlassAppearance.self, forKey: .glass) ?? defaults.glass
        // Read as a string and mapped: an unknown name would throw, and
        // throwing here fails the whole settings file.
        let carriedInk = (try legacy.decodeIfPresent(String.self, forKey: .ink)).flatMap(PanelInk.init(rawValue:))
            ?? defaults.ink
        look = try c.decodeIfPresent(PanelLook.self, forKey: .look)
            ?? PanelLook(glass: carriedGlass, ink: carriedInk)
        // A file written before there were two looks says only what the panel
        // looked like at the time. That is a real choice and it is kept: it
        // becomes whichever pole its ink belongs to, and the other pole starts
        // from the shipped default. Pinned to that pole, so nothing changes
        // under the operator until he asks it to.
        if let stored = try c.decodeIfPresent(ThemeSettings.self, forKey: .theme) {
            theme = stored
        } else {
            let carried = look
            let isDark = look.ink == .light
            theme = ThemeSettings(
                source: .manual,
                manualIsDark: isDark,
                light: isDark ? .light : carried,
                dark: isDark ? carried : .dark
            )
        }
        resolvedIsDark = try c.decodeIfPresent(Bool.self, forKey: .resolvedIsDark) ?? (look.ink == .light)
        quiet = try c.decodeIfPresent(IslandQuiet.self, forKey: .quiet) ?? defaults.quiet
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
        // Read as a string and mapped rather than decoded as the enum, for the
        // same reason as every other name in this file: a language uDeck no
        // longer has should cost the operator that one setting, not the file.
        language = (try c.decodeIfPresent(String.self, forKey: .language)).flatMap(Language.init(rawValue:))
        textSize = try c.decodeIfPresent(CGFloat.self, forKey: .textSize)
    }

    /// These settings with `glass` and `ink` brought into line with the look
    /// that is actually in force.
    ///
    /// Everything that draws reads the resolved pair, so the whole of "which
    /// look is showing" is this one function and the two facts it is handed.
    /// Neither fact belongs in a settings file — what macOS is set to and what
    /// time it is are the world's business, not the operator's.
    public func resolved(systemIsDark: Bool, hour: Int) -> AppSettings {
        var result = self
        result.resolvedIsDark = theme.isDark(systemIsDark: systemIsDark, hour: hour)
        result.look = theme.look(systemIsDark: systemIsDark, hour: hour)
        return result
    }

    /// The look of one state of the island, in the pole in force.
    ///
    /// This is what everything that draws the panel asks for. `look` above is
    /// the same answer for a panel that has only one appearance, and stays the
    /// answer for every state until the operator gives one of them its own.
    public func look(for state: IslandState) -> PanelLook {
        theme.states.look(for: state, isDark: resolvedIsDark, base: look)
    }

    /// Whether the dark look is the one in force.
    public func isDark(systemIsDark: Bool, hour: Int) -> Bool {
        theme.isDark(systemIsDark: systemIsDark, hour: hour)
    }
}
