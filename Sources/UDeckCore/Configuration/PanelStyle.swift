import Foundation

/// What the panel is made of, in both of its variants.
///
/// The redesign of Settings → Look (the operator, 2026-11-19) split two
/// questions the six presets used to answer at once. Whether the panel is light
/// or dark is the appearance (`ThemeAppearance`), one row, as macOS and most
/// applications ask it; what the panel is made of is the style, and every style
/// has a light and a dark variant, so choosing one is one click and never makes
/// "the dark look" light. The six presets (`PanelMode`) were each one variant
/// of a style — Light and Dark are the two of Glass, Paper and Contrast the two
/// of Solid — and the light variants of Smoke and Ghost are new.
public enum PanelStyle: String, CaseIterable, Sendable, Identifiable {
    /// Frosted glass, what uDeck ships wearing.
    case glass
    /// As close to opaque as the material goes: reads over anything.
    case solid
    /// Diffused, but still visibly a material.
    case smoke
    /// Barely a panel: the content hangs over whatever is behind it.
    case ghost

    public var id: String { rawValue }

    /// The variant worn while the appearance is light.
    public var light: PanelLook {
        switch self {
        case .glass: PanelMode.light.look
        case .solid: PanelMode.paper.look
        // Smoke's clear material under a light tint at its strength, dark text.
        case .smoke:
            PanelLook(
                glass: GlassAppearance(style: .clear, opacity: 1, tinted: true, tintIsLight: true, tintStrength: 0.55),
                ink: .dark
            )
        // Ghost's quarter of the material under a light tint, dark text: over
        // a bright window the dark ink is what still reads.
        case .ghost:
            PanelLook(
                glass: GlassAppearance(style: .regular, opacity: 0.35, tinted: true, tintIsLight: true, tintStrength: 0.25),
                ink: .dark
            )
        }
    }

    /// The variant worn while the appearance is dark.
    public var dark: PanelLook {
        switch self {
        case .glass: PanelMode.dark.look
        case .solid: PanelMode.contrast.look
        case .smoke: PanelMode.smoke.look
        case .ghost: PanelMode.ghost.look
        }
    }

    public func look(forDark isDark: Bool) -> PanelLook {
        isDark ? dark : light
    }

    public var namePhrase: Phrase {
        switch self {
        case .glass: .styleGlass
        case .solid: .styleSolid
        case .smoke: .styleSmoke
        case .ghost: .styleGhost
        }
    }

    public var summaryPhrase: Phrase {
        switch self {
        case .glass: .styleGlassSummary
        case .solid: .styleSolidSummary
        case .smoke: .styleSmokeSummary
        case .ghost: .styleGhostSummary
        }
    }
}

/// Whether the panel is light, dark, or follows the Mac — Settings → Look's
/// «Оформление» row, as Slack and macOS ask it.
///
/// A view of `ThemeSource` and `manualIsDark` rather than a setting of its own:
/// the file keeps what it always kept. Following the Mac includes following the
/// clock instead, which is chosen under fine tuning (`ThemeSource.schedule`) —
/// both are "it changes by itself".
public enum ThemeAppearance: String, CaseIterable, Sendable, Identifiable {
    case automatic
    case light
    case dark

    public var id: String { rawValue }

    public var namePhrase: Phrase {
        switch self {
        case .automatic: .appearanceAutomatic
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
    }
}

extension ThemeSettings {
    /// The «Оформление» row's answer, and what choosing on it writes.
    ///
    /// Choosing automatic while the clock is already chosen keeps the clock;
    /// from Light or Dark it follows the Mac — the clock is chosen again under
    /// fine tuning, its hours kept. One stored source, no remembered second one.
    public var appearance: ThemeAppearance {
        get {
            switch source {
            case .system, .schedule: .automatic
            case .manual: manualIsDark ? .dark : .light
            }
        }
        set {
            switch newValue {
            case .automatic: if source == .manual { source = .system }
            case .light: source = .manual; manualIsDark = false
            case .dark: source = .manual; manualIsDark = true
            }
        }
    }

    /// The built-in style both looks are, or `nil` when they are the operator's
    /// own. Values marked the same in every state (`IslandStates.shared`) are
    /// not the style's to decide and are left out of the comparison, as they
    /// are left alone when a style is applied.
    public var style: PanelStyle? {
        PanelStyle.allCases.first { matches(light: $0.light, dark: $0.dark) }
    }

    /// The saved style both looks are, if any.
    public var savedStyle: PanelPreset? {
        saved.first { matches(light: $0.look, dark: $0.darkLook) }
    }

    /// Wears a style: its light variant in the light look, its dark one in the
    /// dark look. Values shared by every state stay as they are.
    ///
    /// The states set up on their own (`IslandStates.light`/`dark`) wear it
    /// too, each keeping how visible it is: a state is set up apart mostly to
    /// fade, and a style that reached the theme and not them would leave the
    /// real panel in the old material while the pane shows the new (Codex,
    /// stage-3 review).
    public mutating func apply(_ style: PanelStyle) {
        apply(light: style.light, dark: style.dark)
    }

    public mutating func apply(_ preset: PanelPreset) {
        apply(light: preset.look, dark: preset.darkLook)
    }

    /// Saves both looks as a style of the operator's own.
    ///
    /// A name already in use is replaced, as `save(_:as:)` does it.
    @discardableResult
    public mutating func saveStyle(as name: String) -> PanelPreset? {
        saveStyle(as: name, light: light, dark: dark)
    }

    /// Saves two looks as a style — a group of states' own, from the page that
    /// sets states up.
    @discardableResult
    public mutating func saveStyle(as name: String, light lightLook: PanelLook, dark darkLook: PanelLook) -> PanelPreset? {
        let cleaned = PanelPreset.cleaned(name: name)
        guard !cleaned.isEmpty else { return nil }
        if let index = saved.firstIndex(where: { $0.name.lowercased() == cleaned.lowercased() }) {
            saved[index].look = lightLook
            saved[index].dark = darkLook
            return saved[index]
        }
        let preset = PanelPreset(name: cleaned, look: lightLook, dark: darkLook)
        saved.append(preset)
        return preset
    }

    private mutating func apply(light newLight: PanelLook, dark newDark: PanelLook) {
        light = newLight.taking(states.shared, from: light)
        dark = newDark.taking(states.shared, from: dark)
        for (id, own) in states.light { states.light[id] = worn(newLight, over: own) }
        for (id, own) in states.dark { states.dark[id] = worn(newDark, over: own) }
    }

    /// A style's variant as a state set up on its own wears it: its visibility
    /// and the values shared by every state stay the state's.
    private func worn(_ variant: PanelLook, over own: PanelLook) -> PanelLook {
        var look = variant.taking(states.shared, from: own)
        look.presence = own.presence
        return look
    }

    private func matches(light candidateLight: PanelLook, dark candidateDark: PanelLook) -> Bool {
        candidateLight.taking(states.shared, from: light) == light
            && candidateDark.taking(states.shared, from: dark) == dark
    }
}
