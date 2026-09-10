import AppKit
import Foundation
import Sparkle
import UDeckKit

/// uDeck's updater: Sparkle for the parts that are hard, and none of its
/// windows.
///
/// Sparkle is the project's first dependency and it earns it. The parts of
/// updating an application that look easy — checking a feed, verifying a
/// signature, replacing a bundle that is currently running, relaunching — are
/// the parts that fail quietly, on the machine of somebody who is not watching.
///
/// What it does *not* get to do is talk. Sparkle's standard driver answers a
/// check with a modal alert, and the most common answer is "you are up to
/// date": an interruption to deliver the least interesting thing the check
/// could have found, in a window uDeck did not draw and cannot translate. So
/// this is a custom `SPUUserDriver` that writes what happened into
/// `UpdateStatus` and shows nothing. The settings screen reads it — installed
/// version, latest version, one sentence — which is where somebody who cares
/// about the answer already is.
///
/// **Automatic checks start off.** uDeck otherwise makes no network connection
/// at all — it asks macOS for no permissions and talks to nothing — so the
/// first outbound connection this application ever makes should be one the
/// operator switched on.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking {
    let status: UpdateStatus
    private var updater: SPUUpdater!
    private let driver = InlineUpdateDriver()

    /// Held from `showUpdateReleaseNotes`-time until the operator presses the
    /// install button: Sparkle hands over a reply block and waits.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?

    override init() {
        let bundle = Bundle.main
        status = UpdateStatus(
            installedVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—"
        )
        super.init()

        driver.owner = self
        updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil
        )
        do {
            try updater.start()
        } catch {
            // A build with no feed configured, or a bundle Sparkle will not
            // update — a bare `swift build` binary is both. Not a reason to
            // fail to launch; a reason for the screen to say so.
            status.stage = .failed(reason: error.localizedDescription)
        }
        status.lastCheck = updater.lastUpdateCheckDate
    }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        status.stage = .checking
        updater.checkForUpdates()
    }

    func install() {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        choice(.install)
    }

    // MARK: - Called by the driver

    fileprivate func found(version: String, choice: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoice = choice
        status.latestVersion = version
        status.stage = .available(version: version)
    }

    fileprivate func finishedCheck(foundSomething: Bool) {
        status.lastCheck = updater.lastUpdateCheckDate ?? Date()
        if !foundSomething {
            status.latestVersion = status.installedVersion
            status.stage = .upToDate
        }
    }

    fileprivate func failed(_ error: any Error) {
        status.stage = .failed(reason: error.localizedDescription)
    }

    fileprivate func downloading(fraction: Double?) {
        status.stage = .downloading(fraction: fraction)
    }

    fileprivate func readyToInstall() {
        status.stage = .readyToInstall(version: status.latestVersion ?? "—")
    }
}

/// Sparkle's user interface, reduced to writing down what happened.
///
/// Every method either records something or acknowledges immediately. Nothing
/// here opens a window, and nothing here blocks Sparkle waiting for a person —
/// except the one place where waiting is the point: an update has been found
/// and nobody has said whether to install it.
@MainActor
private final class InlineUpdateDriver: NSObject, SPUUserDriver {
    weak var owner: SparkleUpdater?

    private var expectedLength: Double = 0
    private var received: Double = 0

    /// Sparkle's own "may I check automatically?" question, which uDeck never
    /// asks: the switch in the settings screen is that question, and asking it
    /// twice in two different voices would be one time too many.
    ///
    /// Answered with whatever the operator has already set, so this is never
    /// reached in practice — `SUEnableAutomaticChecks` in the plist is what
    /// stops Sparkle wanting to ask.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: owner?.checksAutomatically ?? false,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.finishedCheck(foundSomething: true)
        owner?.found(version: appcastItem.displayVersionString, choice: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // "Not found" is Sparkle's error-shaped way of saying the happy thing.
        owner?.finishedCheck(foundSomething: false)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        received = 0
        owner?.downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = Double(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += Double(length)
        owner?.downloading(fraction: expectedLength > 0 ? received / expectedLength : nil)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.downloading(fraction: 1)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.readyToInstall()
        // Nothing to ask: the operator pressed install, and this is the same
        // answer arriving a second time further down Sparkle's own pipeline.
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool, acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {}
}
