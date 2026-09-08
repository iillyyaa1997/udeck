import AppKit
import Carbon.HIToolbox
import OSLog
import UDeckCore

/// Registers one global keyboard shortcut, and tells the panel when it is
/// pressed.
///
/// Deliberately Carbon rather than `NSEvent.addGlobalMonitorForEvents`. The
/// monitor sees every keystroke on the machine and so needs Accessibility;
/// `RegisterEventHotKey` asks the window server to deliver exactly one
/// combination to this process and needs nothing at all. uDeck asks macOS for
/// no permissions, and a keyboard shortcut is the obvious place to lose that
/// property by accident.
@MainActor
public final class HotKeyMonitor {
    /// Called on the main thread when the shortcut is pressed.
    public var onFire: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: HotKeyBinding?

    /// The one monitor a process has. The Carbon callback is a C function
    /// pointer and cannot capture anything, so it needs somewhere to look the
    /// instance up; there is exactly one, and the id below is checked before
    /// this is touched.
    private static var current: HotKeyMonitor?

    /// Identifies our hot key among any others registered in the process, so a
    /// stray event from somewhere else cannot open the panel.
    private static let signature: OSType = 0x7544_636B  // 'uDck'
    private static let identifier: UInt32 = 1

    public init() {}

    /// Registers `binding`, replacing whatever was registered before.
    ///
    /// Safe to call on every settings change: an unchanged binding is left
    /// alone, so holding the key down while dragging a slider does not
    /// re-register it hundreds of times.
    public func apply(_ binding: HotKeyBinding) {
        guard binding != registered else { return }
        unregister()
        registered = binding

        guard binding.enabled else {
            DeckLog.panel.debug("hotkey disabled")
            return
        }
        guard let keyCode = binding.keyCode, binding.isValid else {
            // Reachable only if something bypassed `AppSettings.validated()`,
            // which turns an unregisterable shortcut off. Still said out loud
            // rather than ignored.
            DeckLog.panel.error("hotkey \(binding.key, privacy: .public) cannot be registered")
            return
        }

        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKeyMonitor.signature, id: HotKeyMonitor.identifier)
        let status = RegisterEventHotKey(
            keyCode, binding.carbonModifiers, id, GetEventDispatcherTarget(), 0, &reference
        )
        guard status == noErr, let reference else {
            // The usual cause is another application holding the same
            // combination: the window server gives it to whoever asked first,
            // and there is no way to find out who that is. Naming the shortcut
            // is what turns "the key does nothing" into something fixable.
            DeckLog.panel.error(
                "hotkey \(binding.displayName, privacy: .public) refused by the system (status \(status)) — most likely already taken by another application"
            )
            return
        }
        hotKey = reference
        HotKeyMonitor.current = self
        DeckLog.panel.debug("hotkey \(binding.displayName, privacy: .public) registered")
    }

    public func stop() {
        unregister()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        registered = nil
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if HotKeyMonitor.current === self { HotKeyMonitor.current = nil }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, 1, &spec, nil, &handler)
    }

    /// Called from the Carbon handler once the event has been confirmed to be
    /// ours.
    ///
    /// `nonisolated` because the handler is a C function pointer with no
    /// isolation of its own; Carbon delivers hot keys on the main thread, which
    /// is what makes the assumption below sound rather than hopeful.
    fileprivate nonisolated static func fire() {
        MainActor.assumeIsolated { current?.onFire() }
    }
}

/// The Carbon callback. A plain C function: no captures, no `self`.
private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    // Spelled out rather than `EventHotKeyID()`: the imported no-argument
    // initialiser carries main-actor-isolated defaults, and this closure has no
    // isolation at all.
    var id = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    // Another hot key in this process is not ours to answer.
    guard id.signature == 0x7544_636B, id.id == 1 else { return OSStatus(eventNotHandledErr) }
    HotKeyMonitor.fire()
    return noErr
}
