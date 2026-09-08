import Foundation


/// A colour for the panel's text, when grey is not what is wanted.
///
/// Stored as three numbers rather than as a platform colour because this
/// target has no AppKit and no SwiftUI — the view that needs a `Color` is the
/// one that can make one, and a settings file full of sRGB components is a
/// settings file a person can still read and edit.
public struct InkColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = InkColor(red: 1, green: 1, blue: 1)
    public static let black = InkColor(red: 0.06, green: 0.06, blue: 0.06)

    /// Perceived brightness, for deciding whether a colour belongs on a dark
    /// panel or a light one.
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public func validated() -> InkColor {
        func clamp(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
        return InkColor(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }

    /// See `GlassAppearance.init(from:)` — a half-written colour keeps the rest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try c.decodeIfPresent(Double.self, forKey: .red) ?? 1,
            green: try c.decodeIfPresent(Double.self, forKey: .green) ?? 1,
            blue: try c.decodeIfPresent(Double.self, forKey: .blue) ?? 1
        )
    }

    enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
    }
}

/// One complete look: what the panel is made of, and how it is written on.
///
/// The two travel together because they cannot be chosen apart. Ink is only
/// answerable once the tint is fixed — a panel tinted 72% white needs dark text
/// and a panel tinted 55% black needs light — and the one time they were set
/// independently the operator was handed white text on a white panel.
public struct PanelLook: Codable, Equatable, Sendable {
    public var glass: GlassAppearance

    /// Which way the text is written: light on a dark panel, or dark on a
    /// bright one. The direction, not the shade.
    public var ink: PanelInk

    /// How far the text goes towards its own end of the scale, 0 to 1.
    ///
    /// One means what the panel had before this was a setting — white, or the
    /// near-black that light ink is the opposite of. Turning it down walks the
    /// text back towards the middle, which is what "quieter text" means when
    /// the thing it is written on is already a wash of one colour.
    public var inkBrightness: Double

    /// A colour instead of grey, or `nil` for grey.
    ///
    /// Grey is the right default and stays it: the panel is a wash of one tint
    /// and coloured text on a coloured ground is where legibility goes. But the
    /// panel is the operator's, it sits over his work all day, and there is no
    /// argument from legibility that survives him wanting it green.
    public var inkColor: InkColor?

    public init(
        glass: GlassAppearance = GlassAppearance(),
        ink: PanelInk = .light,
        inkBrightness: Double = 1,
        inkColor: InkColor? = nil
    ) {
        self.glass = glass
        self.ink = ink
        self.inkBrightness = inkBrightness
        self.inkColor = inkColor
    }

    /// The colour the text is actually written in.
    ///
    /// Kept here rather than in the theme so it can be checked without a view.
    /// Brightness is how far the ink travels from the panel's own value towards
    /// its end of the scale, which is the same thing whether the ink is grey or
    /// coloured — so one number does both, and at 1 it lands exactly on what
    /// the panel had before any of this was a setting.
    public var foreground: InkColor {
        let b = min(max(inkBrightness.isFinite ? inkBrightness : 1, 0), 1)
        let base = inkColor ?? (ink == .light ? .white : .black)
        switch ink {
        case .light:
            // Dimming light text walks it down towards the panel it sits on.
            let k = 0.35 + 0.65 * b
            return InkColor(red: base.red * k, green: base.green * k, blue: base.blue * k)
        case .dark:
            // Dimming dark text walks it up towards the panel it sits on.
            let k = 0.35 + 0.65 * b
            // Written as "the colour, plus what is left of the way to white"
            // rather than as "white, minus", so that full brightness lands on
            // the colour itself and not a rounding error away from it.
            let rest = 1 - k
            return InkColor(
                red: base.red + (1 - base.red) * rest,
                green: base.green + (1 - base.green) * rest,
                blue: base.blue + (1 - base.blue) * rest
            )
        }
    }

    public func validated() -> PanelLook {
        var result = self
        result.glass = result.glass.validated()
        result.inkBrightness = result.inkBrightness.isFinite
            ? min(max(result.inkBrightness, 0), 1)
            : 1
        result.inkColor = result.inkColor?.validated()
        return result
    }

    /// The bright pole: a frosted panel with near-black text.
    public static let light = PanelLook(
        glass: GlassAppearance(style: .regular, opacity: 1, tinted: true,
                               tintIsLight: true, tintStrength: 0.72),
        ink: .dark
    )

    /// The dark pole: what uDeck was before any of this was a setting.
    public static let dark = PanelLook(
        glass: GlassAppearance(style: .regular, opacity: 1, tinted: true,
                               tintIsLight: false, tintStrength: 0.55),
        ink: .light
    )

    /// See `GlassAppearance.init(from:)` — a look written by an older build is
    /// missing keys a newer one knows about, and those fall back rather than
    /// failing the whole settings file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PanelLook()
        self.init(
            glass: try c.decodeIfPresent(GlassAppearance.self, forKey: .glass) ?? d.glass,
            ink: (try c.decodeIfPresent(String.self, forKey: .ink)).flatMap(PanelInk.init(rawValue:)) ?? d.ink,
            inkBrightness: try c.decodeIfPresent(Double.self, forKey: .inkBrightness) ?? d.inkBrightness,
            inkColor: try c.decodeIfPresent(InkColor.self, forKey: .inkColor) ?? d.inkColor
        )
    }

    enum CodingKeys: String, CodingKey {
        case glass
        case ink
        case inkBrightness
        case inkColor
    }
}


/// A look the operator saved and named.
///
/// The six that ship are an enum, because they are part of the program and
/// change when it does. These are data: they are made at runtime, they outlive
/// the build, and there can be any number of them — which is the whole
/// difference and the reason they are not the same type.
public struct PanelPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var look: PanelLook

    public init(id: UUID = UUID(), name: String, look: PanelLook) {
        self.id = id
        self.name = name
        self.look = look
    }

    /// A name that will still be one after a person has finished typing.
    ///
    /// Trimmed, and capped well above anything anybody means to type — a preset
    /// list is read at a glance, and one entry three lines tall is a list that
    /// no longer works as one.
    public static func cleaned(name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    /// See `GlassAppearance.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Saved look",
            look: try c.decodeIfPresent(PanelLook.self, forKey: .look) ?? PanelLook()
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case look
    }
}

/// What decides which of the two looks the panel is wearing.
public enum ThemeSource: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whatever macOS is set to. Changes when the system changes, including
    /// when the system is itself on a schedule.
    case system

    /// The one the operator picked. Nothing changes it but him.
    case manual

    /// Light while the sun is up, dark once it is down.
    ///
    /// Deliberately by the clock rather than by sunrise: uDeck asks macOS for
    /// no permissions at all, and location is a permission. A fixed pair of
    /// hours is worse astronomy and the same result for anyone who is not
    /// awake at either end of it.
    case schedule

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .system: "System"
        case .manual: "Manual"
        case .schedule: "By the clock"
        }
    }

    public var summary: String {
        switch self {
        case .system: "Follows macOS, including its own light and dark schedule."
        case .manual: "Stays where you put it."
        case .schedule: "Light during the day, dark at night."
        }
    }
}

/// When the scheduled source turns over, in whole hours of local time.
public struct ThemeSchedule: Codable, Equatable, Sendable {
    /// The hour the light look starts, 0-23.
    public var lightFromHour: Int
    /// The hour the dark look starts, 0-23.
    public var darkFromHour: Int

    public init(lightFromHour: Int = 7, darkFromHour: Int = 19) {
        self.lightFromHour = lightFromHour
        self.darkFromHour = darkFromHour
    }

    /// Whether the dark look is the one in force at that hour.
    ///
    /// Written to survive a schedule that wraps past midnight, which is the
    /// normal case for the dark half and the reason this is not a comparison
    /// between two numbers.
    public func isDark(atHour hour: Int) -> Bool {
        let h = ((hour % 24) + 24) % 24
        let light = ((lightFromHour % 24) + 24) % 24
        let dark = ((darkFromHour % 24) + 24) % 24
        guard light != dark else { return false }
        if light < dark { return h < light || h >= dark }
        return h >= dark && h < light
    }

    public func validated() -> ThemeSchedule {
        ThemeSchedule(
            lightFromHour: ((lightFromHour % 24) + 24) % 24,
            darkFromHour: ((darkFromHour % 24) + 24) % 24
        )
    }

    /// See `GlassAppearance.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSchedule()
        self.init(
            lightFromHour: try c.decodeIfPresent(Int.self, forKey: .lightFromHour) ?? d.lightFromHour,
            darkFromHour: try c.decodeIfPresent(Int.self, forKey: .darkFromHour) ?? d.darkFromHour
        )
    }

    enum CodingKeys: String, CodingKey {
        case lightFromHour
        case darkFromHour
    }
}

/// Everything about which look is showing, kept apart from the looks themselves.
public struct ThemeSettings: Codable, Equatable, Sendable {
    public var source: ThemeSource

    /// Which pole `manual` pins, and the one a source falls back to when it
    /// cannot answer.
    public var manualIsDark: Bool

    public var schedule: ThemeSchedule

    public var light: PanelLook
    public var dark: PanelLook

    /// The operator's own presets, in the order he made them.
    public var saved: [PanelPreset]

    public init(
        source: ThemeSource = .manual,
        manualIsDark: Bool = false,
        schedule: ThemeSchedule = ThemeSchedule(),
        light: PanelLook = .light,
        dark: PanelLook = .dark,
        saved: [PanelPreset] = []
    ) {
        self.source = source
        self.manualIsDark = manualIsDark
        self.schedule = schedule
        self.light = light
        self.dark = dark
        self.saved = saved
    }

    /// Saves the look currently in one of the poles under a name.
    ///
    /// A name already in use replaces what was under it rather than making a
    /// second entry with the same label — two identical names in a list you
    /// pick from is a list you cannot pick from. Names are matched without
    /// regard to case or surrounding space, because that is how a person
    /// re-types a name they mean to overwrite.
    @discardableResult
    public mutating func save(forDark isDark: Bool, as name: String) -> PanelPreset? {
        let cleaned = PanelPreset.cleaned(name: name)
        guard !cleaned.isEmpty else { return nil }
        let preset = PanelPreset(name: cleaned, look: look(forDark: isDark))
        if let index = saved.firstIndex(where: { $0.name.lowercased() == cleaned.lowercased() }) {
            saved[index].look = preset.look
            return saved[index]
        }
        saved.append(preset)
        return preset
    }

    public mutating func remove(_ id: PanelPreset.ID) {
        saved.removeAll { $0.id == id }
    }

    public mutating func apply(_ preset: PanelPreset, forDark isDark: Bool) {
        setLook(preset.look, forDark: isDark)
    }

    /// Whether the dark look is in force.
    ///
    /// - Parameters:
    ///   - systemIsDark: what macOS is set to. Only consulted by `.system`.
    ///   - hour: the local hour. Only consulted by `.schedule`.
    public func isDark(systemIsDark: Bool, hour: Int) -> Bool {
        switch source {
        case .system: systemIsDark
        case .manual: manualIsDark
        case .schedule: schedule.isDark(atHour: hour)
        }
    }

    /// The look in force, whole.
    public func look(systemIsDark: Bool, hour: Int) -> PanelLook {
        isDark(systemIsDark: systemIsDark, hour: hour) ? dark : light
    }

    /// The look the settings screen is editing, which is not always the one
    /// showing: the operator has to be able to set up the dark half in daylight.
    public func look(forDark isDark: Bool) -> PanelLook {
        isDark ? dark : light
    }

    public mutating func setLook(_ look: PanelLook, forDark isDark: Bool) {
        if isDark { dark = look } else { light = look }
    }

    public func validated() -> ThemeSettings {
        var result = self
        result.schedule = result.schedule.validated()
        result.light = result.light.validated()
        result.dark = result.dark.validated()
        result.saved = result.saved.compactMap { preset in
            var preset = preset
            preset.name = PanelPreset.cleaned(name: preset.name)
            guard !preset.name.isEmpty else { return nil }
            preset.look = preset.look.validated()
            return preset
        }
        return result
    }

    /// See `GlassAppearance.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSettings()
        self.init(
            source: (try c.decodeIfPresent(String.self, forKey: .source)).flatMap(ThemeSource.init(rawValue:)) ?? d.source,
            manualIsDark: try c.decodeIfPresent(Bool.self, forKey: .manualIsDark) ?? d.manualIsDark,
            schedule: try c.decodeIfPresent(ThemeSchedule.self, forKey: .schedule) ?? d.schedule,
            light: try c.decodeIfPresent(PanelLook.self, forKey: .light) ?? d.light,
            dark: try c.decodeIfPresent(PanelLook.self, forKey: .dark) ?? d.dark,
            saved: try c.decodeIfPresent([PanelPreset].self, forKey: .saved) ?? d.saved
        )
    }

    enum CodingKeys: String, CodingKey {
        case source
        case manualIsDark
        case schedule
        case light
        case dark
        case saved
    }
}
