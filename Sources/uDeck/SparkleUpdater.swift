import AppKit
import Foundation
import OSLog
import Sparkle
import UDeckCore
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
/// about the answer already is; a notification says a new version (below).
///
/// **Automatic checks start on** (`SUEnableAutomaticChecks` in Info.plist): once
/// an hour (`SUScheduledCheckInterval`, the least Sparkle allows; once a day
/// until 0.8.5, which left a new version a day away) uDeck asks its feed whether
/// there is a newer version, as it reads the official plugin catalogue once a
/// day — both on from the first launch, by the operator's decision that fewer
/// questions for a new person outweigh a quiet first minute. The switch in
/// Settings → About turns it off; README and SECURITY.md say what is asked and
/// when.
///
/// **What a check of its own does with a new version is the operator's choice**
/// (`UpdateMode`, 0.8.6):
/// - *Only tell me*: it is said — on the pane, in a notification — and nothing
///   is downloaded. Sparkle's session ends there (the found version is
///   dismissed, not skipped), so the next hour's look still happens and finds a
///   newer one; **Update** asks Sparkle again and puts in what it finds. Until
///   0.8.6 a found version held the session until **Install**, and no look
///   happened meanwhile: on 2026-11-17 a pressed check found 0.8.4 at 12:07,
///   and 0.8.5, out at 14:32, could not be found until **Install**.
/// - *Download it ahead*: Sparkle downloads and verifies it, and it waits for
///   **Update**, which only restarts. Sparkle's session stays open while it
///   waits, so no look happens meanwhile: a newer one is found after **Update**
///   — or after uDeck quits, when Sparkle puts the download in.
/// - *Install it by itself* (as uDeck ships, and as it has since 0.8.1):
///   downloaded, and instead of waiting for uDeck to quit — a menu-bar app
///   hardly ever does — uDeck restarts into it as soon as nothing holds it
///   (`restartHold`): the panel away, Settings not in use, no Sign in, plugin
///   operation or card action under way. It looks again every minute until
///   then, and its log says what holds it each time that changes
///   (`DeckLog.updates`).
///
/// A pressed **Check now** follows the mode for downloading — in the two that
/// download, what it finds is downloaded at once — and never restarts by
/// itself: that is **Update**'s.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking, SPUUpdaterDelegate {
    let status: UpdateStatus
    /// The notification about an update (`UpdateNotice`).
    let notifier = UpdateNotifier()
    private var updater: SPUUpdater!
    private let driver = InlineUpdateDriver()
    private let defaults = UserDefaults.standard

    /// Where uDeck keeps what Sparkle does not: the mode, the notification
    /// switch, the version the last notice sent was about, and the version
    /// uDeck last restarted into by itself.
    private static let modeKey = "UDeckUpdateMode"
    private static let notifiesKey = "UDeckUpdateNotifies"
    private static let notifiedKey = "UDeckUpdateNotifiedVersions"
    private static let restartedIntoKey = "UDeckUpdateRestartedInto"
    /// Sparkle's own name for "download what a check of its own finds".
    private static let sparkleDownloadsKey = "SUAutomaticallyUpdate"

    /// A found version Sparkle resumed already downloaded, held until
    /// **Update**: Sparkle hands over a reply block and waits.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    /// A version a pressed check downloaded, held at Sparkle's "ready to
    /// install" until **Update**.
    private var pendingReady: ((SPUUserUpdateChoice) -> Void)?
    /// **Update** pressed on a version found and let go: the check it started
    /// puts in what it finds.
    private var installRequested = false
    /// **Update** pressed: what reaches "ready to install" goes in at once.
    private var installWhenReady = false
    /// Versions whose notice is on its way to macOS: not sent twice meanwhile.
    private var noticesUnderWay: Set<String> = []
    /// A notice macOS refused or failed to take, sent again once it allows
    /// notifications (`refreshNotificationPermission`).
    private var unsentNotice: UpdateNotice?

    /// What holds a restart into an update now, or nil: set by the
    /// application (`DeckModel.restartHold`).
    var restartHold: () -> RestartHold? = { nil }
    /// The last answer `restartHold` gave while an update waited, so that the
    /// log says each change once rather than every minute.
    private var saidHold: RestartHold??

    /// Held from `willInstallUpdateOnQuit` until uDeck restarts into the update
    /// Sparkle downloaded by itself.
    private var pendingRestart: (() -> Void)?
    private var restartTimer: Timer?
    /// Whether uDeck asked Sparkle, with nothing pressed, to restart it into
    /// an update: the termination that follows is checked once more
    /// (`mayTerminateForAnUpdate`).
    private(set) var restartingByItself = false
    /// Whether the termination ahead is uDeck going into an update — by
    /// itself or pressed for: what makes the application leave Settings'
    /// place for the launch after it (`SettingsPlace`).
    private(set) var restartingIntoAnUpdate = false

    override init() {
        let bundle = Bundle.main
        status = UpdateStatus(
            installedVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—"
        )
        super.init()

        driver.owner = self
        notifier.onUpdate = { [weak self] in self?.install() }
        notifier.start()
        updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self
        )
        // The first launch after 0.8.5 keeps what its one switch meant, read
        // from what it stored (`SUAutomaticallyUpdate`), the plist's when it
        // stored nothing.
        if defaults.string(forKey: Self.modeKey) == nil {
            let downloads = defaults.object(forKey: Self.sparkleDownloadsKey) as? Bool
                ?? bundle.object(forInfoDictionaryKey: Self.sparkleDownloadsKey) as? Bool ?? false
            let mode = UpdateMode.kept(nil, automaticallyDownloads: downloads)
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            DeckLog.updates.notice("update mode: \(mode.rawValue, privacy: .public), from 0.8.5's switch")
        }
        do {
            try updater.start()
            // Sparkle downloads exactly when the mode says so, whatever it kept.
            let mode = updateMode
            if updater.automaticallyDownloadsUpdates != mode.downloadsAhead {
                updater.automaticallyDownloadsUpdates = mode.downloadsAhead
            }
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
        set {
            updater.automaticallyChecksForUpdates = newValue
            if newValue { restartWhenItMay() } else { stopWaitingToRestart() }
        }
    }

    var updateMode: UpdateMode {
        get { UpdateMode.kept(defaults.string(forKey: Self.modeKey), automaticallyDownloads: updater.automaticallyDownloadsUpdates) }
        set {
            defaults.set(newValue.rawValue, forKey: Self.modeKey)
            updater.automaticallyDownloadsUpdates = newValue.downloadsAhead
            DeckLog.updates.notice("update mode: \(newValue.rawValue, privacy: .public)")
            // Off, an update already downloaded waits for Update; by itself
            // again, it waits for its moment once more.
            if newValue.restartsByItself { restartWhenItMay() } else { stopWaitingToRestart() }
        }
    }

    var notifiesAboutUpdates: Bool {
        get { defaults.object(forKey: Self.notifiesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.notifiesKey) }
    }

    func refreshNotificationPermission() {
        notifier.permission { [weak self] refused in
            guard let self else { return }
            self.status.notificationsRefused = refused
            // Allowed since a notice was refused: it goes now.
            if refused == false, let notice = self.unsentNotice {
                self.unsentNotice = nil
                self.post(notice)
            }
        }
    }

    /// A launch into the version uDeck restarted into by itself is said in a
    /// notification; the note of that restart is taken either way, so that it
    /// is for one launch.
    func noteLaunch() {
        let restartedInto = defaults.string(forKey: Self.restartedIntoKey)
        defaults.removeObject(forKey: Self.restartedIntoKey)
        // What the last run offered is not on offer now.
        notifier.withdrawOffers()
        tell(.launched(running: status.installedVersion, restartedInto: restartedInto))
    }

    func checkNow() {
        // A downloaded update holds Sparkle's session: it stays on the screen,
        // for Update, rather than a check Sparkle would refuse.
        guard pendingRestart == nil, pendingReady == nil, updater.canCheckForUpdates else { return }
        status.stage = .checking
        updater.checkForUpdates()
    }

    func install() {
        installWhenReady = true
        // Pressed: whatever uDeck restarts into now, it did not by itself.
        defaults.removeObject(forKey: Self.restartedIntoKey)
        notifier.withdrawOffers()
        if let restart = pendingRestart {
            restartingByItself = false
            restartNow(restart)
            return
        }
        if let ready = pendingReady {
            pendingReady = nil
            readyToInstall()
            ready(.install)
            return
        }
        if let choice = pendingChoice {
            pendingChoice = nil
            // Installing already, Sparkle goes straight to the restart: no
            // "ready" comes back to say so.
            readyToInstall()
            choice(.install)
            return
        }
        // Found and let go — or a notification's Update after a relaunch, with
        // nothing on the pane: ask again, and put in what is found. A check
        // already under way puts it in when it finds it.
        installRequested = true
        guard updater.canCheckForUpdates else { return }
        status.stage = .checking
        updater.checkForUpdates()
    }

    // MARK: - Put in place by itself

    /// Sparkle has downloaded and verified an update by itself, and would put
    /// it in place when uDeck quits: in `installByItself` uDeck takes that
    /// over and restarts into it now, or — something holding it — once nothing
    /// does, asked every minute; in `downloadAhead` it waits for **Update**.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        status.latestVersion = item.displayVersionString
        status.stage = .readyToInstall(version: item.displayVersionString)
        pendingRestart = immediateInstallHandler
        if installWhenReady {
            // Update was pressed while Sparkle downloaded by itself: in now, as pressed.
            installRequested = false
            installWhenReady = false
            restartingByItself = false
            restartNow(immediateInstallHandler)
            return true
        }
        tell(.downloaded(version: item.displayVersionString))
        restartWhenItMay()
        return true
    }

    /// Whether a restart into an update downloaded by itself may happen with
    /// nothing pressed: automatic checks on, and the mode is to install by itself.
    private var restartsByItself: Bool {
        updater.automaticallyChecksForUpdates && updateMode.restartsByItself
    }

    private func restartWhenItMay() {
        guard let restart = pendingRestart, restartsByItself else { return }
        if holdNow() == nil {
            restartingByItself = true
            // Noted for the launch after it: "uDeck updated" is said then.
            defaults.set(status.latestVersion, forKey: Self.restartedIntoKey)
            restartNow(restart)
            return
        }
        guard restartTimer == nil else { return }
        restartTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingRestart != nil else { return }
                guard self.restartsByItself else { return self.stopWaitingToRestart() }
                if self.holdNow() == nil { self.restartWhenItMay() }
            }
        }
    }

    /// What holds the restart now, said in the log when that changed.
    private func holdNow() -> RestartHold? {
        let hold = restartHold()
        if saidHold != .some(hold) {
            saidHold = .some(hold)
            let version = status.latestVersion ?? "the update"
            if let hold {
                DeckLog.updates.notice("restart into \(version, privacy: .public) waits: \(hold.reason, privacy: .public)")
            } else {
                DeckLog.updates.notice("restart into \(version, privacy: .public): nothing holds it")
            }
        }
        return hold
    }

    /// The handler is kept: Sparkle installs asynchronously and asks uDeck to
    /// terminate later, and a termination refused then is retried with it.
    private func restartNow(_ restart: () -> Void) {
        stopWaitingToRestart()
        restartingIntoAnUpdate = true
        restart()
    }

    /// Asked when uDeck is about to terminate: false — and the restart tried
    /// again later — when that termination is a restart uDeck asked for by
    /// itself and something started meanwhile (Settings opened, an action, an
    /// install). Any other quit goes ahead, and Sparkle puts the update in
    /// place as uDeck quits.
    func mayTerminateForAnUpdate() -> Bool {
        guard restartingByItself, pendingRestart != nil else { return true }
        guard holdNow() != nil else { return true }
        restartingByItself = false
        restartingIntoAnUpdate = false
        defaults.removeObject(forKey: Self.restartedIntoKey)
        restartWhenItMay()
        return false
    }

    /// No more restarts with nothing pressed; what was downloaded stays for
    /// Update — and Sparkle still puts it in place when uDeck quits.
    private func stopWaitingToRestart() {
        restartTimer?.invalidate()
        restartTimer = nil
    }

    // MARK: - Notices

    /// The notification `event` is worth, if any, sent — and remembered once
    /// macOS took it. Through the current API a refusal or a failure is known,
    /// and the notice goes again once notifications are allowed. Through the
    /// older one, all an application signed ad hoc has, macOS says nothing of a
    /// refusal: a "Don't Allow" there costs that version's notice.
    private func tell(_ event: UpdateEvent) {
        guard let notice = UpdateNotice.after(
            event, mode: updateMode, notifies: notifiesAboutUpdates,
            notified: notifiedVersions.union(noticesUnderWay)
        ) else { return }
        post(notice)
    }

    private func post(_ notice: UpdateNotice) {
        noticesUnderWay.insert(notice.version)
        notifier.post(notice) { [weak self] delivery in
            guard let self else { return }
            self.noticesUnderWay.remove(notice.version)
            self.status.notificationsRefused = delivery == .refused
            if delivery == .sent {
                // The last few are kept: a version withdrawn from the feed and
                // found again is still not news.
                self.defaults.set(Array((self.notifiedVersions.union([notice.version])).sorted().suffix(20)),
                                  forKey: Self.notifiedKey)
            } else {
                self.unsentNotice = notice
            }
        }
    }

    /// The versions a notice was sent about.
    private var notifiedVersions: Set<String> {
        Set(defaults.stringArray(forKey: Self.notifiedKey) ?? [])
    }

    // MARK: - What a check of its own came to

    // A check of its own that downloads goes through Sparkle's automatic
    // driver, which asks the user driver nothing: what it found, or did not, is
    // written here, as the user driver writes it for the others.

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status.latestVersion = item.displayVersionString
        // A mode that downloads is downloading it now, by itself: the pane says
        // so rather than an Update that would only wait for it. (What Sparkle
        // will not download by itself comes back through `found`, which says
        // otherwise.)
        if updateMode.downloadsAhead { status.stage = .downloading(fraction: nil) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard pendingRestart == nil else { return }
        finishedCheck(foundSomething: false)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Not finding anything is Sparkle's error too: the call above said it.
        let error = error as NSError
        guard !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) else { return }
        // Its session is over: nothing left to restart into, and Check now may ask again.
        pendingRestart = nil
        pendingReady = nil
        pendingChoice = nil
        restartingByItself = false
        restartingIntoAnUpdate = false
        installRequested = false
        installWhenReady = false
        defaults.removeObject(forKey: Self.restartedIntoKey)
        saidHold = nil
        stopWaitingToRestart()
        failed(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate ?? status.lastCheck
        // Update's own check is over, whatever it came to.
        installRequested = false
        if pendingChoice == nil, pendingReady == nil, pendingRestart == nil { installWhenReady = false }
    }

    // MARK: - Called by the driver

    /// Sparkle found `item`. Whether it is put in, held, or said and let go
    /// depends on who asked and on the mode.
    fileprivate func found(_ item: SUAppcastItem, state: SPUUserUpdateState,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = item.displayVersionString
        finishedCheck(foundSomething: true)
        status.latestVersion = version
        if item.isInformationOnlyUpdate {
            // Nothing to download — uDeck's feed has none of these — so said and let go, whatever was pressed.
            installRequested = false
            status.stage = .available(version: version)
            tell(.foundByItself(version: version))
            reply(.dismiss)
            return
        }
        if state.stage != .notDownloaded {
            // Already downloaded, or installing: Sparkle resumed it. It waits for Update.
            pendingChoice = reply
            status.stage = .readyToInstall(version: version)
            if installWhenReady {
                install()
            } else if !state.userInitiated {
                DeckLog.updates.notice("\(version, privacy: .public) resumed downloaded; it waits for Update")
                tell(.downloaded(version: version))
            }
            return
        }
        if installRequested {
            // Update was pressed on it: download and put it in.
            installRequested = false
            status.stage = .downloading(fraction: nil)
            reply(.install)
            return
        }
        if state.userInitiated, updateMode.downloadsAhead {
            // Check now, in a mode that downloads: downloaded at once, and it
            // waits at "ready to install" for Update.
            status.stage = .downloading(fraction: nil)
            reply(.install)
            return
        }
        // Said, and let go: Sparkle's session ends, and the next look happens.
        status.stage = .available(version: version)
        tell(.foundByItself(version: version))
        DeckLog.updates.notice("found \(version, privacy: .public)\(state.userInitiated ? " by Check now" : " by itself", privacy: .public); it waits for Update")
        reply(.dismiss)
    }

    /// Sparkle's answer to "Check now" while an update is held for the
    /// operator: it does not check again, it asks for that update to be
    /// brought forward. `checkNow` has already said "checking", so the update
    /// is put back on the screen — otherwise the pane would say "checking"
    /// forever over an Update button it never draws.
    fileprivate func updateBroughtForward() {
        guard pendingChoice != nil || pendingReady != nil, let version = status.latestVersion else { return }
        status.stage = .readyToInstall(version: version)
    }

    fileprivate func finishedCheck(foundSomething: Bool) {
        status.lastCheck = updater.lastUpdateCheckDate ?? Date()
        if !foundSomething {
            status.latestVersion = status.installedVersion
            status.stage = .upToDate
        }
    }

    fileprivate func failed(_ error: any Error) {
        installRequested = false
        status.stage = .failed(reason: error.localizedDescription)
    }

    fileprivate func downloading(fraction: Double?) {
        status.stage = .downloading(fraction: fraction)
    }

    /// Downloaded and verified at Sparkle's "ready to install": in at once when
    /// Update was pressed, else held for it.
    fileprivate func ready(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installWhenReady else {
            pendingReady = reply
            let version = status.latestVersion ?? "—"
            status.stage = .readyToInstall(version: version)
            DeckLog.updates.notice("\(version, privacy: .public) downloaded by Check now; it waits for Update")
            tell(.downloaded(version: version))
            return
        }
        readyToInstall()
        reply(.install)
    }

    /// Installed now: what follows is the termination into it — not at
    /// **Update**, which a download and a quit can still come between.
    private func readyToInstall() {
        status.stage = .readyToInstall(version: status.latestVersion ?? "—")
        restartingIntoAnUpdate = true
    }
}

/// Sparkle's user interface, reduced to writing down what happened.
///
/// Every method either records something or acknowledges immediately. Nothing
/// here opens a window, and nothing here blocks Sparkle waiting for a person —
/// except where waiting is the point: a version downloaded or resumed that the
/// operator has not said to put in.
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
    /// reached in practice — `SUEnableAutomaticChecks` in the plist answers the
    /// question before Sparkle would want to ask it.
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
        guard let owner else { return reply(.dismiss) }
        owner.found(appcastItem, state: state, reply: reply)
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
        guard let owner else { return reply(.dismiss) }
        owner.ready(reply: reply)
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

    func showUpdateInFocus() {
        owner?.updateBroughtForward()
    }

    func dismissUpdateInstallation() {}
}
