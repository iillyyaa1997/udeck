import AppKit
import Foundation
import ServiceManagement
import UDeckCore
import UDeckKit

/// The system's own record of whether uDeck opens at login, asked and changed through
/// `SMAppService`.
///
/// This is the only file in uDeck that touches `ServiceManagement`, and it does as little
/// as a file can: it translates four framework values into uDeck's four words, and it
/// asks. Everything that decides what the operator is told lives in `LoginItemJudgement`,
/// where it can be tested without registering anything on anybody's Mac — which is also
/// why this class is in the executable target, which has no test target: `swift test`
/// cannot construct it, so no test run can leave a login item behind.
@MainActor
final class SystemLoginItem: LoginItemControlling {
    let status = LoginItemStatus()

    let thisCopy: URL

    private let service: SMAppService
    private let now: () -> Date
    private let copiesOnDisk: @MainActor () -> [URL]

    init(
        service: SMAppService = .mainApp,
        now: @escaping () -> Date = Date.init,
        thisCopy: URL = Bundle.main.bundleURL,
        copiesOnDisk: @escaping @MainActor () -> [URL] = SystemLoginItem.copiesOnDisk
    ) {
        self.service = service
        self.now = now
        self.thisCopy = thisCopy
        self.copiesOnDisk = copiesOnDisk
    }

    func refresh() {
        status.otherCopies = otherCopies(than: thisCopy, among: copiesOnDisk())
        status.read(LoginItemReading(state: Self.state(of: service.status), at: now()))
    }

    /// Every copy of uDeck this Mac knows about, from Launch Services.
    ///
    /// Public API, no permission asked for and none needed — which is the whole reason
    /// this is worth doing: the record itself is out of reach, and the copies are not.
    static func copiesOnDisk() -> [URL] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
    }

    func set(opensAtLogin: Bool) {
        // The card draws the switch disabled for a copy like this, so nothing should ever
        // arrive here — which is the reason to refuse it here too. This is the one place
        // in uDeck that asks the system to change a login record, and a development build
        // asking carries the release identifier to a path under `.build`.
        guard isAnInstalledCopy(thisCopy) else {
            status.read(LoginItemReading(
                state: .couldNotAsk(reason: "this copy of uDeck is not an installed application"),
                at: now()
            ))
            return
        }

        status.operatorAsked(toOpen: opensAtLogin)
        do {
            if opensAtLogin {
                // Registering something already registered throws
                // `kSMErrorAlreadyRegistered`, and each successful registration makes
                // macOS post "Login Item Added" — an application that registers on every
                // launch shows that banner at every login.
                if service.status != .enabled { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            status.read(LoginItemReading(state: .couldNotAsk(reason: reason(for: error)), at: now()))
            DeckLog.panel.debug("login item: \(String(describing: error), privacy: .public)")
            return
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The framework's four cases in uDeck's words.
    ///
    /// `notFound` is documented as "the system has never seen this service", and it is
    /// also what comes back once a record is gone — the two are indistinguishable from
    /// here, which is exactly why the judgement decides what may be said about it.
    static func state(of status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled: .opens
        case .notRegistered: .doesNot
        case .requiresApproval: .waitsForApproval
        case .notFound: .systemHasNoRecord
        @unknown default: .couldNotAsk(reason: "the system answered with something this version does not know")
        }
    }

    /// The error as a person can act on it.
    ///
    /// The domain is printed rather than compared: `SMAppServiceErrorDomain` is macOS 15
    /// and uDeck runs on 14, and the numbers are what the reports about this API quote at
    /// each other anyway — `kSMErrorAlreadyRegistered`, "Operation not permitted".
    private func reason(for error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }
}
