import CoreGraphics
import Foundation
import UDeckPluginFormat

/// What keeps uDeck from restarting into an update it put in place by itself:
/// something under way that the restart would cut short.
///
/// The first that holds is the one said, in uDeck's log (`DeckLog.updates`),
/// each time the answer changes — so that "why has it not updated?" is read,
/// not guessed. On 2026-11-17 a 0.8.1 waited three and a half hours for a
/// settings window left open behind other windows, and its log said nothing.
public enum RestartHold: String, Sendable, Equatable, CaseIterable {
    /// The panel is out.
    case panel
    /// Settings is in use (`SettingsUse`).
    case settings
    /// A Sign in is under way: a code shown, the host asked at its interval.
    /// It ends by itself — the code expires — so it never holds for long.
    case signIn
    /// A plugin is being installed, updated, removed or linked.
    case pluginOperation
    /// A card action is running.
    case cardAction

    /// The first of them that holds, or nil: uDeck may restart now.
    public static func first(
        panelOut: Bool, settingsInUse: Bool, signIn: Bool, pluginOperation: Bool, cardAction: Bool
    ) -> RestartHold? {
        if panelOut { return .panel }
        if settingsInUse { return .settings }
        if signIn { return .signIn }
        if pluginOperation { return .pluginOperation }
        if cardAction { return .cardAction }
        return nil
    }

    /// What the log says.
    public var reason: String {
        switch self {
        case .panel: "the panel is out"
        case .settings: "Settings is in use"
        case .signIn: "a Sign in is under way"
        case .pluginOperation: "a plugin is being installed, updated, removed or linked"
        case .cardAction: "a card action is running"
        }
    }
}

/// Whether the settings window holds a restart into an update.
///
/// It used to hold it for as long as the window was on the screen, and a
/// window can be on the screen for days without anybody in it: behind other
/// windows, on another desktop. So it holds only while it is in use — touched
/// in the last `quiet`, or in front of somebody who is at the Mac (`frontQuiet`,
/// up to `frontCeiling` from the last touch) — and a restart that happens with
/// it open opens it again where it was (`SettingsPlace`).
///
/// A form open in it — a source being added, a token being pasted, a link
/// being looked up — is work a restart would lose, and the person may be in
/// a browser making the token it asks for: it holds for `formQuiet` after the
/// last touch. Not for ever: a form forgotten open is a window forgotten open.
public enum SettingsUse {
    /// Three minutes: longer than a pause to read a pane, shorter than a
    /// window forgotten.
    public static let quiet: TimeInterval = 180
    /// Thirty minutes: room to make a token on GitHub's or GitLab's pages and
    /// come back with it.
    public static let formQuiet: TimeInterval = 1800
    /// Ten minutes: in front of somebody, the window is being read, and a
    /// reader keeps their hands still longer than a clicker does.
    public static let frontQuiet: TimeInterval = 600
    /// Thirty minutes from the last touch, whatever else moves: a pointer
    /// something nudges — a screen-sharing viewer, a drifting mouse — is not
    /// somebody reading for ever.
    public static let frontCeiling: TimeInterval = 1800

    /// - Parameters:
    ///   - shown: whether the window is on the screen.
    ///   - inFront: whether uDeck is the active application, its settings
    ///     window — or a panel or popover of it — taking the keyboard.
    ///   - sinceTouched: how long since a click, a key or a scroll in uDeck
    ///     while it was on the screen, or since it was opened; nil if never.
    ///   - sinceAnyInput: how long since any input on this Mac at all.
    ///   - formOpen: whether a form is open in it.
    public static func inUse(
        shown: Bool, inFront: Bool, sinceTouched: TimeInterval?, sinceAnyInput: TimeInterval?,
        formOpen: Bool = false
    ) -> Bool {
        guard shown else { return false }
        if true { return false }
        if let sinceTouched, sinceTouched < (formOpen ? formQuiet : quiet) { return true }
        if inFront, let sinceAnyInput, sinceAnyInput < frontQuiet,
           let sinceTouched, sinceTouched < frontCeiling { return true }
        return false
    }
}

/// Where the settings window was when uDeck restarted into an update: what
/// the restarted uDeck opens it at again — the pane, the window's frame, and
/// whether it was in front, behind, or in the Dock. Not what was typed in a form: a form closes with
/// the window, as it always has (`SettingsUse.formQuiet`).
///
/// Written only by a restart into an update with the window on the screen,
/// to `settings-to-reopen.json` in uDeck's folder, and taken — read and
/// removed — by the next launch, which opens it only if it is fresh
/// (`keptFor`): a uDeck that was not relaunched after the update, and opened
/// by hand a day later, opens as it always does.
public struct SettingsPlace: Codable, Equatable, Sendable {
    /// The window's frame, in screen coordinates as AppKit gives them.
    public struct Frame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        /// Whether enough of it is on one of `screens` (their visible frames)
        /// to be taken hold of: a frame left on a display that is gone is not
        /// put back, and the window opens where it always does.
        public func isOnScreen(_ screens: [CGRect], atLeast: Double = 80) -> Bool {
            guard width > 0, height > 0 else { return false }
            return screens.contains { screen in
                let shared = rect.intersection(screen)
                return !shared.isNull && shared.width >= atLeast && shared.height >= atLeast
            }
        }
    }

    /// The pane, by its identifier (`section.<this>` in the window).
    public var section: String
    public var frame: Frame?
    /// Whether it was the key window of the active application: opened in
    /// front again, or else behind, without taking the keyboard from what
    /// somebody is typing in.
    public var inFront: Bool
    /// Whether it was minimized into the Dock: put back there.
    public var minimized: Bool
    public var savedAt: Date

    /// Ten minutes: room for Sparkle's install and relaunch many times over.
    public static let keptFor: TimeInterval = 600

    public init(section: String, frame: Frame?, inFront: Bool, minimized: Bool = false, savedAt: Date) {
        self.section = section
        self.frame = frame
        self.inFront = inFront
        self.minimized = minimized
        self.savedAt = savedAt
    }

    /// Whether it was written in the last `keptFor` — and not later than a
    /// minute from now, which only a clock set back could have done.
    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age > -60 && age < Self.keptFor
    }

    /// The place `store` holds, if it is fresh — and the file gone whatever it
    /// held, fresh, stale or unreadable: it is for one launch.
    public static func take(from store: JSONFileStore<SettingsPlace>, now: Date = Date()) -> SettingsPlace? {
        let place = try? store.load()
        try? FileManager.default.removeItem(at: store.url)
        guard let place, place.isFresh(at: now) else { return nil }
        return place
    }
}

extension UDeckPaths {
    /// Where a restart into an update leaves the settings window's place
    /// (`SettingsPlace`), for the launch after it.
    public var settingsToReopenFile: URL { root.appendingPathComponent("settings-to-reopen.json") }
}
