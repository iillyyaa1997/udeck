import Foundation
import Observation

/// Where an update check has got to.
///
/// Modelled as one value rather than a handful of booleans because the states
/// are exclusive and a screen that can show "checking" and "up to date" at once
/// is a screen that will.
public enum UpdateStage: Equatable, Sendable {
    /// Nothing has happened yet in this run.
    case idle

    case checking

    /// Checked, and there is nothing newer.
    case upToDate

    /// There is a newer version, and this is its number.
    case available(version: String)

    case downloading(fraction: Double?)

    /// Downloaded and ready; the application restarts to finish.
    case readyToInstall(version: String)

    /// The check itself failed — no network, a feed that would not parse, a
    /// signature that did not verify.
    case failed(reason: String)
}

/// What the settings screen shows about updating, kept outside the view so it
/// survives the window being closed and reopened mid-check.
@MainActor
@Observable
public final class UpdateStatus {
    public var stage: UpdateStage = .idle

    /// When the last check finished. Sparkle keeps its own copy across
    /// launches; this is the one the screen reads.
    public var lastCheck: Date?

    /// The version now running, as the operator would read it.
    public var installedVersion: String

    /// The newest version the feed offered, once anything has been read from
    /// it. Stays after a check that found nothing newer, because "installed
    /// 0.1.0, latest 0.1.0" is a more convincing answer than "up to date".
    public var latestVersion: String?

    public init(installedVersion: String, lastCheck: Date? = nil) {
        self.installedVersion = installedVersion
        self.lastCheck = lastCheck
    }
}

/// What the settings screen needs from an updater, and nothing more.
///
/// The updater itself lives in the executable target, not here. `UDeckKit` has
/// no dependencies of its own and this is not the place to acquire the first
/// one: a settings screen needs a switch, two version numbers, a button and a
/// sentence, none of which says anything about how an update is fetched or
/// verified.
///
/// It also means the settings screen renders in a build with no updater — which
/// is what `swift build && .build/debug/uDeck` is.
@MainActor
public protocol UpdateChecking: AnyObject {
    /// Whether uDeck looks for a new version on its own.
    ///
    /// Off until the operator turns it on. uDeck makes no network connection of
    /// any kind otherwise, and an application that quietly starts talking to a
    /// server because it was updated is doing something the operator did not
    /// ask for — even when the server is its own.
    var checksAutomatically: Bool { get set }

    /// Everything the screen draws.
    var status: UpdateStatus { get }

    /// Look now. The answer appears in `status` rather than in a window: a
    /// modal alert saying "you are up to date" interrupts to deliver the least
    /// interesting thing the check could possibly have found.
    func checkNow()

    /// Install what has been downloaded, restarting to finish.
    func install()
}
