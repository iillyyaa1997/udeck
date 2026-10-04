import CoreServices
import Foundation
import UDeckCore

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
///
/// **And the folders linked plugins lead to.** A linked folder's files are
/// not under the plugins folder, so editing its manifest there would go
/// unnoticed: every folder a link leads to is watched beside it
/// (`WatchedFolders`), and the list is renewed each time the plugins folder is
/// read — a link pointed elsewhere, or taken away, is a change in the plugins
/// folder itself, and the next read watches where it leads now.
///
/// Two streams, so that what changed is told by where it was seen: a working
/// copy is written into all the time, and a change there reads the plugins
/// folder again and hashes no installed plugin (`FolderChange`,
/// `WatchedFolders.rehashes(after:)`).
@MainActor
public final class PluginFolderWatcher {
    /// How long FSEvents batches before it tells us. Long enough that a folder
    /// copied in arrives as one event rather than one per file.
    private static let latency: CFTimeInterval = 0.3

    /// How long to wait after the last event before re-reading. Covers the case
    /// FSEvents' own window does not: an archive expanding over a few seconds.
    private static let settle: TimeInterval = 0.4

    /// The plugins folder's stream, and the one of the folders links lead to.
    private var pluginsStream: FSEventStreamRef?
    private var linkedStream: FSEventStreamRef?
    private var pending: Timer?
    /// Where something changed since the last time it was told.
    private var changes: Set<FolderChange> = []
    private let onChange: (Set<FolderChange>) -> Void
    /// What the linked folders' stream watches now, as the paths it was given.
    private var watched: [String] = []

    public init(onChange: @escaping (Set<FolderChange>) -> Void) {
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
        pluginsStream = Self.stream([directory.path], for: self, seen: .pluginsFolder)
    }

    /// Watches `folders` — the folders linked plugins lead to — from now on,
    /// starting that stream again only when the list changed. Nothing is
    /// created here: a folder a link leads to is the author's, and only ever
    /// read.
    public func watch(_ folders: [URL]) {
        let paths = folders.map(\.path)
        guard paths != watched else { return }
        Self.end(linkedStream)
        linkedStream = paths.isEmpty ? nil : Self.stream(paths, for: self, seen: .linkedFolder)
        watched = paths
    }

    /// A stream of `paths` whose events say `seen`, on the main queue.
    private static func stream(_ paths: [String], for watcher: PluginFolderWatcher, seen: FolderChange) -> FSEventStreamRef? {
        let callback: FSEventStreamCallback = { stream, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PluginFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // FSEvents calls back on the queue it was scheduled on, which is the
            // main queue below; `assumeIsolated` states that rather than hopping.
            MainActor.assumeIsolated { watcher.somethingChanged(in: stream) }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(watcher).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            // WatchRoot: the folder itself being moved or replaced is a change
            // like any other. FileEvents: per-file rather than per-directory, so
            // a manifest edited in place is reported.
            UInt32(kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents)
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        return stream
    }

    private static func end(_ stream: FSEventStreamRef?) {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    public func stop() {
        pending?.invalidate()
        pending = nil
        changes = []
        Self.end(pluginsStream)
        Self.end(linkedStream)
        pluginsStream = nil
        linkedStream = nil
        watched = []
    }

    private func somethingChanged(in stream: ConstFSEventStreamRef) {
        // Where it was seen is the stream it came from: anything but the
        // plugins folder's is a folder a link leads to.
        changes.insert(stream == pluginsStream ? .pluginsFolder : .linkedFolder)
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changes = self.changes
                self.changes = []
                self.onChange(changes)
            }
        }
    }
}
