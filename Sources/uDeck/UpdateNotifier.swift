import AppKit
import Foundation
@preconcurrency import UserNotifications
import UDeckCore
import UDeckKit

/// The notification about an update (0.8.6, `UpdateNotice`): macOS's own, in
/// the corner of the screen, at most one for each version.
///
/// Found or downloaded, it carries **Update** and **Later**; after a restart
/// into the new version, nothing to press. Clicking it opens Settings → General,
/// where the version, **Update** and "What's new" are. macOS asks whether uDeck
/// may send notifications the first time there is one to send — not at launch —
/// and a refusal is said in General's updates (`UpdateStatus.notificationsRefused`).
///
/// **An application signed ad hoc is refused the current API.** macOS answers
/// uDeck's `requestAuthorization` with "Notifications are not allowed for this
/// application" before asking anybody — lab runs 44138977236 and 44151756110,
/// with NotificationCenter running, and on the operator's Mac on 2026-11-17 —
/// and uDeck has no Developer ID yet. The older `NSUserNotificationCenter` is
/// used then: deprecated since macOS 11, and measured working the same day on
/// the operator's Mac with an application signed as uDeck is — macOS asked
/// whether it may send notifications, and after Allow the banner showed. Through
/// it macOS does not say whether it was refused, so About's "off in macOS"
/// line speaks only for the current API, once uDeck is signed.
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    static let offerCategory = "place.unicorns.udeck.update.offer"
    static let updateAction = "place.unicorns.udeck.update.update"
    static let laterAction = "place.unicorns.udeck.update.later"

    /// The words, in uDeck's language at the moment one is sent.
    var strings: () -> Strings = { Strings(.english) }
    /// **Update** pressed in the notification.
    var onUpdate: () -> Void = {}
    /// The notification itself clicked.
    var onOpen: () -> Void = {}
    /// A resident plugin's notice clicked: (plugin id, the plugin's notice id).
    var onOpenPluginNotice: (String, String) -> Void = { _, _ in }
    /// A button of a resident plugin's notice pressed, or a reply written in
    /// it: (plugin id, notice id, the button's id, the reply).
    var onAnswerPluginNotice: (String, String, String?, String?) -> Void = { _, _, _, _ in }

    static let pluginPrefix = "plugin\u{1F}"
    static let pluginActionPrefix = "place.unicorns.udeck.plugin.action\u{1F}"
    static let pluginReplyAction = "place.unicorns.udeck.plugin.reply"
    /// The categories of plugins' notices with buttons or a field, by
    /// identifier: macOS keeps one set of categories for the application, the
    /// update's offer among them, so the whole set is given each time.
    private var pluginCategories: [String: UNNotificationCategory] = [:]
    /// The newest last: the oldest go once there are more than this.
    private var pluginCategoryOrder: [String] = []
    static let pluginCategoryLimit = 32

    /// A notification a resident plugin asked for; a newer one with the same
    /// id replaces it. Its buttons and its field, if it has them, come as a
    /// category of its own. Through the current API, which a signed uDeck has.
    func postPluginNotice(plugin: String, notice: PluginNotice) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = String(notice.body.prefix(240))
        content.sound = .default
        content.threadIdentifier = plugin
        if notice.answers {
            let category = pluginCategory(for: notice)
            if pluginCategories[category.identifier] == nil {
                pluginCategories[category.identifier] = category
                pluginCategoryOrder.append(category.identifier)
                if pluginCategoryOrder.count > Self.pluginCategoryLimit {
                    pluginCategories[pluginCategoryOrder.removeFirst()] = nil
                }
            }
            content.categoryIdentifier = category.identifier
            setCategories()
        }
        let identifier = Self.pluginPrefix + plugin + "\u{1F}" + notice.id
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let center = center
        Task { @MainActor in
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                // Read back: the category is in the set before the notice
                // that names it is.
                _ = await center.notificationCategories()
                try await center.add(request)
            } catch {
                DeckLog.updates.notice("plugin notice not sent: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Takes a plugin's notice away, shown or waiting to be.
    func withdrawPluginNotice(plugin: String, id: String) {
        guard bundled else { return }
        let identifier = Self.pluginPrefix + plugin + "\u{1F}" + id
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// A category for what `notice` offers: its buttons, then its field. Named
    /// by what it holds, so that notices offering the same share one.
    private func pluginCategory(for notice: PluginNotice) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = notice.actions.map {
            UNNotificationAction(identifier: Self.pluginActionPrefix + $0.id, title: $0.text, options: [])
        }
        if let reply = notice.reply {
            actions.append(UNTextInputNotificationAction(
                identifier: Self.pluginReplyAction, title: reply.button, options: [],
                textInputButtonTitle: strings()(.noticeSend), textInputPlaceholder: reply.placeholder ?? ""))
        }
        let parts = notice.actions.map { $0.id + "\u{1F}" + $0.text }
            + [notice.reply.map { $0.button + "\u{1F}" + ($0.placeholder ?? "") } ?? "", strings()(.noticeSend)]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1E}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return UNNotificationCategory(identifier: "place.unicorns.udeck.plugin." + String(hash, radix: 16),
                                      actions: actions, intentIdentifiers: [])
    }

    /// Every category uDeck's notices use: the update's offer, and the
    /// plugins'.
    private func setCategories() {
        let strings = strings()
        let offer = UNNotificationCategory(
            identifier: Self.offerCategory,
            actions: [
                UNNotificationAction(identifier: Self.updateAction, title: strings(.updatesUpdate)),
                UNNotificationAction(identifier: Self.laterAction, title: strings(.noticeLater)),
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories(Set([offer] + pluginCategoryOrder.compactMap { pluginCategories[$0] }))
    }

    /// What became of one: macOS took it, said no, or failed to.
    enum Delivery: Equatable { case sent, refused, failed }

    private var center: UNUserNotificationCenter { .current() }

    /// Whether uDeck runs from its bundle: `UNUserNotificationCenter.current()`
    /// raises an exception Swift cannot catch in a bare `swift build` binary,
    /// which runs here otherwise as a whole development loop.
    private let bundled = Bundle.main.bundleURL.pathExtension == "app"

    /// Set before launching finishes, so that a click that launched uDeck
    /// reaches it.
    func start() {
        guard bundled else { return }
        center.delegate = self
        NSUserNotificationCenter.default.delegate = self
    }

    /// Takes away what was offered and is on offer no more — found or
    /// downloaded, once Update was pressed or uDeck relaunched — so that an
    /// old banner in the list does not offer it again.
    func withdrawOffers() {
        guard bundled else { return }
        let offers = NSUserNotificationCenter.default.deliveredNotifications.filter {
            $0.identifier?.hasPrefix("update found ") == true || $0.identifier?.hasPrefix("update downloaded ") == true
        }
        offers.forEach(NSUserNotificationCenter.default.removeDeliveredNotification)
        let center = center
        Task { @MainActor in
            let ids = await center.deliveredNotifications().map(\.request.identifier)
                .filter { $0.hasPrefix("update found ") || $0.hasPrefix("update downloaded ") }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Send `notice`, asking macOS first when it has not been asked; `done` is
    /// told what became of it.
    func post(_ notice: UpdateNotice, done: @escaping @MainActor (Delivery) -> Void) {
        guard bundled else {
            DeckLog.updates.notice("notice \(notice.key, privacy: .public) not sent: uDeck is not running from its bundle")
            done(.failed)
            return
        }
        let strings = strings()
        setCategories()
        let content = UNMutableNotificationContent()
        switch notice {
        case .found(let version):
            content.title = strings(.noticeFoundTitle(version))
            content.body = strings(.noticeFoundBody)
        case .downloaded(let version):
            content.title = strings(.noticeDownloadedTitle(version))
            content.body = strings(.noticeDownloadedBody)
        case .updated(let version):
            content.title = strings(.noticeUpdatedTitle(version))
            content.body = strings(.noticeUpdatedBody)
        }
        if notice.offersUpdate { content.categoryIdentifier = Self.offerCategory }
        let request = UNNotificationRequest(identifier: "update \(notice.key)", content: content, trigger: nil)
        let key = notice.key
        let center = center
        Task { @MainActor in
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    DeckLog.updates.notice("notice \(key, privacy: .public): macOS does not allow uDeck's notifications")
                    done(.refused)
                    return
                }
                try await center.add(request)
                DeckLog.updates.notice("notice \(key, privacy: .public): sent")
                done(.sent)
            } catch let error as UNError where error.code == .notificationsNotAllowed {
                // Refused before anybody was asked: an application signed ad hoc.
                DeckLog.updates.notice("notice \(key, privacy: .public): \(error.localizedDescription, privacy: .public); trying NSUserNotificationCenter")
                done(self.postTheOldWay(notice, strings: strings, key: key))
            } catch {
                DeckLog.updates.error("notice \(key, privacy: .public) not sent: \(error.localizedDescription, privacy: .public)")
                let settings = await center.notificationSettings()
                done(settings.authorizationStatus == .denied ? .refused : .failed)
            }
        }
    }

    /// Whether macOS refuses uDeck's notifications: nil when it has not been
    /// asked — and for an application signed ad hoc, which the current API
    /// reports as never asked (status 0, measured on the operator's Mac).
    func permission(_ answer: @escaping @MainActor (Bool?) -> Void) {
        guard bundled else { return answer(nil) }
        let center = center
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .denied: answer(true)
            case .notDetermined: answer(nil)
            default: answer(false)
            }
        }
    }

    /// The same notice through `NSUserNotificationCenter`: sent when macOS
    /// lists it as delivered.
    @available(macOS, deprecated: 11.0)
    private func postTheOldWay(_ notice: UpdateNotice, strings: Strings, key: String) -> Delivery {
        let note = NSUserNotification()
        note.identifier = "update \(key)"
        switch notice {
        case .found(let version):
            note.title = strings(.noticeFoundTitle(version))
            note.informativeText = strings(.noticeFoundBody)
        case .downloaded(let version):
            note.title = strings(.noticeDownloadedTitle(version))
            note.informativeText = strings(.noticeDownloadedBody)
        case .updated(let version):
            note.title = strings(.noticeUpdatedTitle(version))
            note.informativeText = strings(.noticeUpdatedBody)
        }
        note.hasActionButton = notice.offersUpdate
        if notice.offersUpdate {
            note.actionButtonTitle = strings(.updatesUpdate)
            note.otherButtonTitle = strings(.noticeLater)
        }
        let center = NSUserNotificationCenter.default
        center.deliver(note)
        // Handed over is all this API says. Its list of what it delivered lags
        // the hand-over — read at once, it held the notice in one lab run and
        // not in the next (44164447486) — so it is said in the log, not judged.
        let listed = center.deliveredNotifications.contains(where: { $0.identifier == note.identifier })
        DeckLog.updates.notice("notice \(key, privacy: .public): sent (NSUserNotificationCenter\(listed ? ", listed as delivered" : "", privacy: .public))")
        return .sent
    }

    // MARK: - NSUserNotificationCenterDelegate

    /// Shown even while uDeck is the active application.
    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true
    }

    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        let pressedUpdate = notification.activationType == .actionButtonClicked
        let opened = notification.activationType == .contentsClicked
        Task { @MainActor in self.activated(pressedUpdate: pressedUpdate, opened: opened) }
    }

    /// A notice clicked while uDeck was not running launches it, and macOS hands
    /// the click over in the launch's own notification rather than to the
    /// delegate: read there.
    func launched(with userInfo: [AnyHashable: Any]?) {
        guard let note = userInfo?[NSApplication.launchUserNotificationUserInfoKey] as? NSUserNotification,
              note.identifier?.hasPrefix("update ") == true else { return }
        activated(pressedUpdate: note.activationType == .actionButtonClicked,
                  opened: note.activationType == .contentsClicked)
    }

    private func activated(pressedUpdate: Bool, opened: Bool) {
        if pressedUpdate {
            DeckLog.updates.notice("notice: Update pressed")
            onUpdate()
        } else if opened {
            DeckLog.updates.notice("notice: opened")
            onOpen()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while uDeck is the active application — with Settings open,
    /// say — rather than only into Notification Centre's list.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        let written = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if identifier.hasPrefix(Self.pluginPrefix) {
                let parts = identifier.dropFirst(Self.pluginPrefix.count).split(separator: "\u{1F}", maxSplits: 1)
                guard parts.count == 2 else { return }
                let (plugin, notice) = (String(parts[0]), String(parts[1]))
                // A button or a reply is an answer, given where it was asked:
                // the plugin is told, and the panel stays as it is.
                if action.hasPrefix(Self.pluginActionPrefix) {
                    onAnswerPluginNotice(plugin, notice, String(action.dropFirst(Self.pluginActionPrefix.count)), nil)
                } else if action == Self.pluginReplyAction {
                    let text = (written ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { onAnswerPluginNotice(plugin, notice, nil, text) }
                } else if action == UNNotificationDefaultActionIdentifier {
                    onOpenPluginNotice(plugin, notice)
                }
                return
            }
            switch action {
            case Self.updateAction:
                DeckLog.updates.notice("notice: Update pressed")
                onUpdate()
            case UNNotificationDefaultActionIdentifier:
                DeckLog.updates.notice("notice: opened")
                onOpen()
            default:
                // Later, or dismissed: not about this version again.
                break
            }
        }
    }
}
