import Foundation
import Observation
import UDeckCore

/// What the settings screen shows about opening at login, kept outside the view so that a
/// reading taken while the window was closed is still the one on screen when it opens.
///
/// It holds a `LoginItemJudgement` and nothing else: no boolean of its own, no copy of
/// the setting in preferences. The judgement's rule — that "the record went away" can
/// only be said by an application that watched it go — is the whole reason this is a
/// value from the layer with no frameworks in it rather than a flag maintained here.
@MainActor
@Observable
public final class LoginItemStatus {
    public private(set) var judgement = LoginItemJudgement()

    public init() {}

    /// What the switch shows. The system's answer, never a memory of what was asked.
    public var opensAtLogin: Bool { judgement.opensAtLogin }

    /// What there is to say about it, if anything. Nothing, on an ordinary day.
    public var trouble: LoginItemTrouble? { judgement.trouble }

    /// When the system last answered.
    public var lastRead: Date? { judgement.reading?.at }

    public func read(_ reading: LoginItemReading) { judgement.read(reading) }

    /// Say that the operator is the reason the next answer will be different, and which
    /// way they asked — so their own switching off is never reported back to them as
    /// something that went wrong, and an "on" the system quietly refuses is.
    public func operatorAsked(toOpen: Bool) { judgement.operatorAsked(toOpen: toOpen) }
}

/// What the settings screen needs from the system's login-item record, and nothing more.
///
/// The implementation lives in the executable target, next to the Sparkle one and for the
/// same reason: `UDeckKit` has no dependencies and a settings screen needs a switch, a
/// sentence and a button — none of which says anything about `ServiceManagement`. It also
/// means the screen renders in `swift build && .build/debug/uDeck`, where there is no
/// bundle to register and nothing may be registered by accident.
@MainActor
public protocol LoginItemControlling: AnyObject {
    /// Everything the screen draws.
    var status: LoginItemStatus { get }

    /// Ask the system again.
    ///
    /// There is no notification when a login item changes — `ServiceManagement` publishes
    /// none — so the only way to stay honest is to ask at the moments when the answer
    /// could have changed without uDeck: when the settings window appears, and when the
    /// application is activated again after the operator has been in System Settings.
    func refresh()

    /// Ask the system to open uDeck at login, or to stop.
    ///
    /// Registering when the system already has it registered is both unnecessary and
    /// visible: macOS shows "Login Item Added" each time, and an application that
    /// registers on every launch shows it at every login — the bug Things fixed in
    /// 3.16.2.
    func set(opensAtLogin: Bool)

    /// Open the system's own Login Items pane, which is the only place some of these
    /// states can be resolved. It cannot be scrolled to uDeck's row: the API takes no
    /// argument and the pane declares no anchor.
    func openSystemSettings()
}
