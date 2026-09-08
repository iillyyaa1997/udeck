import Foundation

/// Keeps a block-based notification observer alive, and removes it when this
/// object goes away.
///
/// `NotificationCenter` hands back an opaque, non-`Sendable` token, which under
/// strict concurrency cannot be touched from a `deinit` on an actor-isolated
/// type. Holding it here instead keeps the ownership obvious — the observer
/// lives exactly as long as the token — without any type having to remember to
/// unregister.
///
/// The unchecked conformance is sound because the token is written once during
/// initialisation and read once during deallocation, and `removeObserver` is
/// documented as safe to call from any thread.
final class NotificationToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let observer: any NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        object: Any? = nil,
        queue: OperationQueue? = .main,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        self.observer = center.addObserver(forName: name, object: object, queue: queue, using: block)
    }

    deinit { center.removeObserver(observer) }
}
