import Foundation

/// Every on-disk location uDeck uses, resolved from one root so that tests can
/// point the whole app at a temporary directory.
///
/// The root defaults to `~/.udeck`. It can be overridden with the `UDECK_HOME`
/// environment variable, which is what the test suite and the `examples/`
/// fixtures rely on — nothing in the codebase is allowed to build a path by
/// concatenating onto `NSHomeDirectory()` directly.
public struct UDeckPaths: Sendable, Equatable {
    /// `~/.udeck` unless overridden.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves the root from the environment, falling back to `~/.udeck`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> UDeckPaths {
        if let override = environment["UDECK_HOME"], !override.isEmpty {
            return UDeckPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                                        isDirectory: true))
        }
        return UDeckPaths(root: home.appendingPathComponent(".udeck", isDirectory: true))
    }

    /// One directory per plugin: `~/.udeck/plugins/<id>/manifest.json`.
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }

    /// Scratch space handed to plugins as `UDECK_CACHE_DIR`, one directory per plugin.
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    public func cache(forPlugin id: PluginIdentifier) -> URL {
        cache.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// Tabs, windows and their grid placement.
    public var layoutFile: URL { root.appendingPathComponent("layout.json") }

    /// Appearance, gesture tuning, density — everything under the app's own control.
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    /// Which capabilities the operator has granted to which plugin.
    public var grantsFile: URL { root.appendingPathComponent("grants.json") }

    /// Per-plugin values for the settings a manifest declares.
    public var pluginSettingsFile: URL { root.appendingPathComponent("plugin-settings.json") }

    /// Directories uDeck creates on first launch. Creating them is the caller's
    /// job so that read-only code paths never have a filesystem side effect.
    public var directoriesToCreate: [URL] { [root, plugins, cache] }
}
