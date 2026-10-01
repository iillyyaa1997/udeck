#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Every on-disk location uDeck uses, resolved from one root so that tests can
/// point the whole app at a temporary directory.
///
/// The root defaults to `~/.udeck`. It can be overridden with the `UDECK_HOME`
/// environment variable, which is what the test suite and the `examples/`
/// fixtures rely on — nothing in the codebase is allowed to build a path by
/// concatenating onto `NSHomeDirectory()` directly. (Reading the variable is
/// uDeck's: `UDeckPaths.fromEnvironment`, in UDeckCore.)
///
/// Here, in the format's package, because the layout is part of what a plugin
/// is on a Mac — `plugins/<id>/` and a cache folder of its own — and
/// `udeck-plugin` puts things where uDeck looks for them: `run` a cache folder,
/// `link` a link in `plugins/`.
public struct UDeckPaths: Sendable, Equatable {
    /// `~/.udeck` unless overridden.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// One directory per plugin: `~/.udeck/plugins/<id>/manifest.json`.
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }

    /// Scratch space handed to plugins as `UDECK_CACHE_DIR`, one directory per plugin.
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    public func cache(forPlugin id: PluginIdentifier) -> URL {
        cache.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// The plugin's cache folder, made if it is not there: before every run,
    /// as the contract says (`UDECK_CACHE_DIR`, "created before each run").
    /// A folder that cannot be made is the run's to find out about — the
    /// producer is told where it is either way.
    @discardableResult
    public func makeCache(forPlugin id: PluginIdentifier) -> URL {
        let folder = cache(forPlugin: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Tabs, windows and their grid placement.
    public var layoutFile: URL { root.appendingPathComponent("layout.json") }

    /// Appearance, gesture tuning, density — everything under the app's own control.
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    /// Which capabilities the operator has granted to which plugin.
    public var grantsFile: URL { root.appendingPathComponent("grants.json") }

    /// Per-plugin values for the settings a manifest declares.
    public var pluginSettingsFile: URL { root.appendingPathComponent("plugin-settings.json") }

    /// Every plugin uDeck installed from a repository: where it came from, and
    /// what it was when it was put there. See docs/plugin-repository.md.
    public var installedFile: URL { root.appendingPathComponent("installed.json") }

    /// What uDeck knows about each plugin repository: listings by commit,
    /// manifests by hash, the limit. Not under `cache/`, where every folder
    /// belongs to a plugin of the same name and `catalogue` is a legal id.
    public var catalogue: URL { root.appendingPathComponent("catalogue", isDirectory: true) }

    /// Where an install, update or removal assembles its work before one rename
    /// puts it in place: beside `plugins/`, so on the same volume, and outside
    /// it, so the folder watcher never sees a half-written plugin.
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// Directories uDeck creates on first launch. Creating them is the caller's
    /// job so that read-only code paths never have a filesystem side effect.
    public var directoriesToCreate: [URL] { [root, plugins, cache] }
}
