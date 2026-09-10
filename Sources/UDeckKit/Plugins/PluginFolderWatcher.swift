import CoreServices
import Foundation

/// Watches the plugins folder and says when something in it changed.
///
/// Without this the list of plugins is whatever was on disk when uDeck started.
/// Copying a plugin in did nothing until the operator found the "Look again"
/// button, and — the way it was actually noticed — removing one left it in the
/// picker, offering to add a plugin that was no longer there.
///
/// FSEvents rather than a `DispatchSource` on the directory: a directory source
/// reports entries appearing and disappearing and nothing else, and half of
/// what matters here happens *inside* a plugin's folder. Editing a manifest,
/// dropping in a translation and making a producer executable are all changes
/// the operator expects to see, and none of them touches the folder above.
///
/// Events are coalesced twice — once by FSEvents itself over its own latency
/// window, and once here — because copying a plugin in is a burst of them and
/// re-reading every manifest per file would be work for nothing.
@MainActor
public final class PluginFolderWatcher {
    /// How long FSEvents batches before it tells us. Long enough that a folder
    /// copied in arrives as one event rather than one per file.
    private static let latency: CFTimeInterval = 0.3

    /// How long to wait after the last event before re-reading. Covers the case
    /// FSEvents' own window does not: an archive expanding over a few seconds.
    private static let settle: TimeInterval = 0.4

    private var stream: FSEventStreamRef?
    private var pending: Timer?
    private let onChange: () -> Void

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    // No `deinit`. The stream cannot be released from a nonisolated deinit
    // without lying about isolation, and the object lives as long as the model
    // that owns it, which lives as long as the application. `stop()` is there
    // for the case that changes.

    /// Starts watching `directory`, creating it if it is not there.
    ///
    /// The folder has to exist to be watched, and an operator who has never
    /// installed a plugin does not have one — so a watcher that gave up here
    /// would be a watcher that never worked for exactly the person most likely
    /// to add their first plugin.
    public func start(watching directory: URL) {
        stop()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PluginFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // FSEvents calls back on the queue it was scheduled on, which is the
            // main queue below; `assumeIsolated` states that rather than hopping.
            MainActor.assumeIsolated { watcher.somethingChanged() }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            // WatchRoot: the folder itself being moved or replaced is a change
            // like any other. FileEvents: per-file rather than per-directory, so
            // a manifest edited in place is reported.
            UInt32(kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        pending?.invalidate()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func somethingChanged() {
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
    }
}
