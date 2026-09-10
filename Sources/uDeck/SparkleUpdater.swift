import Foundation
import Sparkle
import UDeckKit

/// uDeck's updater, which is Sparkle with the smallest possible amount of uDeck
/// wrapped around it.
///
/// Sparkle is the project's first dependency and it earns it. The parts of
/// updating an application that look easy — checking a feed, downloading,
/// replacing a bundle that is currently running, relaunching — are the parts
/// that fail quietly, and a broken updater is worse than none: it fails on the
/// machine of somebody who is not watching.
///
/// What is configured here rather than in `Info.plist`:
///
/// **Automatic checks start off.** uDeck otherwise makes no network connection
/// at all — it asks macOS for no permissions and talks to nothing — so the
/// first outbound connection this application ever makes should be one the
/// operator switched on. `SUEnableAutomaticChecks` is `false` in the plist for
/// the same reason; this reads and writes the operator's own answer.
///
/// **The check is scheduled, not immediate.** Sparkle's own scheduler waits out
/// `SUScheduledCheckInterval` from the last check rather than checking at
/// launch, which matters for an application that is launched at login and left
/// running for weeks.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking {
    private let controller: SPUStandardUpdaterController

    override init() {
        // `startingUpdater: true` starts the scheduler; whether it does
        // anything is `automaticallyChecksForUpdates`, below.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        super.init()
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkNow() {
        // The controller's action, not `updater.checkForUpdates()`: this is the
        // one that shows the operator what happened, including "you already
        // have the newest version". A check somebody asked for that answers
        // with silence reads as a check that did not work.
        controller.checkForUpdates(nil)
    }
}
