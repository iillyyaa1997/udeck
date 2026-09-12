import Foundation

/// What is on the screen behind the panel, as far as the panel's appearance is
/// concerned.
///
/// Two cases rather than a list of applications on purpose. The operator asked
/// for this about a game and about a film, and the answer he wanted was the
/// same in both: it is not "which application" that matters, it is that
/// something has taken the whole screen and the island is the only thing on it
/// that is not that something.
public enum IslandSurrounding: String, Codable, CaseIterable, Sendable {
    /// The desktop and ordinary windows.
    case ordinary

    /// Another application is full-screen.
    case fullscreenApp = "fullscreen"
}

/// One situation the island can be in: a phase, and what is behind it.
///
/// Eight of them, and every one is a place the operator can decide how the
/// panel looks. They are a pair rather than a flat list of eight names because
/// that is what they are — the phases already exist in `PanelPhase` and the
/// surroundings already exist in the gesture code, and inventing eight names
/// would mean maintaining a mapping nobody reads.
public struct IslandState: Hashable, Sendable, CaseIterable {
    public var phase: PanelPhase
    public var surrounding: IslandSurrounding

    public init(phase: PanelPhase, surrounding: IslandSurrounding = .ordinary) {
        self.phase = phase
        self.surrounding = surrounding
    }

    public static var allCases: [IslandState] {
        IslandSurrounding.allCases.flatMap { surrounding in
            PanelPhase.allCases.map { IslandState(phase: $0, surrounding: surrounding) }
        }
    }

    /// `collapsed.ordinary`, `peek.fullscreen`, and so on.
    ///
    /// A settings file is read by people, and a pair of nested objects for
    /// something that is really one coordinate reads worse than a name with a
    /// dot in it.
    public var id: String { "\(phase.rawValue).\(surrounding.rawValue)" }

    public init?(id: String) {
        let parts = id.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let phase = PanelPhase(rawValue: String(parts[0])),
              let surrounding = IslandSurrounding(rawValue: String(parts[1]))
        else { return nil }
        self.init(phase: phase, surrounding: surrounding)
    }
}

extension IslandState: Codable {
    public init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let state = IslandState(id: id) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(id) is not a state uDeck has"
            ))
        }
        self = state
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// States that are edited together.
///
/// Named nothing. A link is not a preset and does not want a name: naming it
/// would mean inventing one, remembering it and recognising it in a list, and
/// what the operator actually wants to know is which states move together —
/// which is a thing to be drawn, not read.
public struct IslandLink: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var states: [IslandState]

    public init(id: UUID = UUID(), states: [IslandState]) {
        self.id = id
        self.states = states
    }
}

/// A single value in a look.
///
/// Used for the values the operator wants to keep the same everywhere — "цвет
/// текста одной настройкой на все". A field marked shared is taken from the
/// theme's own look whatever link a state belongs to, which is what makes it
/// stronger than any link.
public enum LookField: String, Codable, CaseIterable, Sendable {
    case glassStyle
    case glassOpacity
    case tinted
    case tintDirection
    case tintStrength
    case tintColour
    case ink
    case inkBrightness
    case inkColour
}

/// How the island looks in each of its states, for one theme.
///
/// The links are here rather than beside each pole because they are structure,
/// not colour: the operator groups "закрыт" with "закрыт поверх полноэкранного"
/// once, and both the light and the dark half of the day inherit that grouping
/// with their own numbers in it.
public struct IslandStates: Codable, Equatable, Sendable {
    /// A partition of the eight states. Every state belongs to exactly one
    /// link; a link with a single state in it is a state on its own.
    public var links: [IslandLink]

    /// Values taken from the theme's own look rather than from any link.
    public var shared: Set<LookField>

    /// What each link looks like, by theme. Absent means "whatever the theme's
    /// own look says", which is what every link says on the day this arrives.
    public var light: [UUID: PanelLook]
    public var dark: [UUID: PanelLook]

    public init(
        links: [IslandLink] = [IslandLink(states: IslandState.allCases)],
        shared: Set<LookField> = [],
        light: [UUID: PanelLook] = [:],
        dark: [UUID: PanelLook] = [:]
    ) {
        self.links = links
        self.shared = shared
        self.light = light
        self.dark = dark
    }

    /// The link a state belongs to, or `nil` while a settings file is missing
    /// one — in which case the theme's own look answers for it.
    public func link(for state: IslandState) -> IslandLink? {
        links.first { $0.states.contains(state) }
    }

    /// The look of one state, with the shared values folded in.
    public func look(for state: IslandState, isDark: Bool, base: PanelLook) -> PanelLook {
        guard let link = link(for: state) else { return base }
        let stored = (isDark ? dark : light)[link.id]
        guard let stored else { return base }
        return stored.taking(shared, from: base)
    }

    /// Every state belonging to exactly one link, with nothing invented.
    ///
    /// A settings file can say anything: the same state twice, a state uDeck no
    /// longer has, a link with nothing in it. None of that is worth refusing
    /// the file over, and all of it has one obvious reading — first mention
    /// wins, unknown states are dropped, empty links go away, and whatever was
    /// never mentioned joins a link of its own so it still has somewhere to be.
    public func validated() -> IslandStates {
        var result = self
        var seen = Set<IslandState>()
        result.links = links.compactMap { link in
            var link = link
            link.states = link.states.filter { seen.insert($0).inserted }
            return link.states.isEmpty ? nil : link
        }
        let missing = IslandState.allCases.filter { !seen.contains($0) }
        if !missing.isEmpty {
            result.links.append(IslandLink(states: missing))
        }
        let ids = Set(result.links.map(\.id))
        result.light = result.light.filter { ids.contains($0.key) }.mapValues { $0.validated() }
        result.dark = result.dark.filter { ids.contains($0.key) }.mapValues { $0.validated() }
        return result
    }

    enum CodingKeys: String, CodingKey {
        case links
        case shared
        case light
        case dark
    }

    /// Tolerant, like everything else in the settings file: a missing piece is
    /// the default, and an unreadable field name is dropped rather than fatal.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IslandStates()
        links = try c.decodeIfPresent([IslandLink].self, forKey: .links) ?? defaults.links
        let names = try c.decodeIfPresent([String].self, forKey: .shared) ?? []
        shared = Set(names.compactMap(LookField.init(rawValue:)))
        light = try c.decodeIfPresent([UUID: PanelLook].self, forKey: .light) ?? [:]
        dark = try c.decodeIfPresent([UUID: PanelLook].self, forKey: .dark) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(links, forKey: .links)
        try c.encode(shared.map(\.rawValue).sorted(), forKey: .shared)
        try c.encode(light, forKey: .light)
        try c.encode(dark, forKey: .dark)
    }
}

public extension PanelLook {
    /// This look, with the named values taken from another one.
    ///
    /// The other look is the theme's own — what the settings screen shows when
    /// nothing is selected, and what a value marked "the same everywhere" is
    /// kept in. Written as a copy rather than a lookup at every read so that
    /// the rest of the application keeps receiving one finished `PanelLook`
    /// and never has to know which half of it came from where.
    func taking(_ fields: Set<LookField>, from other: PanelLook) -> PanelLook {
        guard !fields.isEmpty else { return self }
        var result = self
        for field in fields {
            switch field {
            case .glassStyle: result.glass.style = other.glass.style
            case .glassOpacity: result.glass.opacity = other.glass.opacity
            case .tinted: result.glass.tinted = other.glass.tinted
            case .tintDirection: result.glass.tintIsLight = other.glass.tintIsLight
            case .tintStrength: result.glass.tintStrength = other.glass.tintStrength
            case .tintColour: result.glass.tintColor = other.glass.tintColor
            case .ink: result.ink = other.ink
            case .inkBrightness: result.inkBrightness = other.inkBrightness
            case .inkColour: result.inkColor = other.inkColor
            }
        }
        return result
    }
}
