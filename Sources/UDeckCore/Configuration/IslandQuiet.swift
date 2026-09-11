import Foundation

/// How far the island fades back while nobody is using it.
///
/// The panel hangs at the top of the screen all day, and most of that day it is
/// a thin pill nobody is reading. Over a full-screen game or a film it is the
/// only thing on screen that is not the film. The operator asked for the same
/// thing in both cases and in the same words: *«не мешало, но было видно»* —
/// so this is one number, the opacity the island keeps when it is away, and it
/// applies wherever the island is collapsed rather than only over full-screen
/// windows.
///
/// Deliberately not part of `PanelLook`. A look is what the panel is made of;
/// this is a rule about when to show less of it, and the difference matters
/// because the rule is about to grow: the per-state looks this is the first
/// step towards will fold this value in rather than sit beside it.
public struct IslandQuiet: Codable, Equatable, Sendable {
    /// Five percent is the floor rather than zero: an island that is completely
    /// invisible is one the operator cannot find with the pointer, and finding
    /// it with the pointer is how it comes back.
    public static let levelRange: ClosedRange<Double> = 0.05 ... 1

    /// Waking is nearly immediate and fading is not.
    ///
    /// The two directions carry different meanings. Coming back is an answer to
    /// something the operator just did, and an answer that takes a third of a
    /// second reads as the application thinking about it. Going quiet is not an
    /// answer to anything — it happens while attention is elsewhere, and a fade
    /// that is slow enough not to catch the eye is the whole point.
    public static let wakeDuration: TimeInterval = 0.12
    public static let fadeDuration: TimeInterval = 0.3

    public var enabled: Bool

    /// What is left of the island while it is away, 0.05 to 1.
    public var level: Double

    public init(enabled: Bool = false, level: Double = 0.35) {
        self.enabled = enabled
        self.level = level
    }

    /// The island's opacity in a given phase.
    ///
    /// Only `collapsed` is quietened. Every other phase is the operator looking
    /// at the panel on purpose, and dimming what somebody is reading is a
    /// different feature that nobody asked for.
    public func opacity(for phase: PanelPhase) -> Double {
        guard enabled, phase == .collapsed else { return 1 }
        return clampedLevel
    }

    /// How long a move to `opacity` should take.
    public static func duration(reaching opacity: Double) -> TimeInterval {
        opacity < 1 ? fadeDuration : wakeDuration
    }

    /// `level` brought inside its range, for a settings file edited by hand.
    public var clampedLevel: Double {
        guard level.isFinite else { return Self.levelRange.lowerBound }
        return min(max(level, Self.levelRange.lowerBound), Self.levelRange.upperBound)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case level
    }

    /// Tolerant of missing keys, like the settings file around it: a file
    /// written before this existed says nothing, and nothing means off.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IslandQuiet()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? defaults.level
    }
}
