#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why a poll is happening. Passed to the producer so it can, for instance,
/// skip an expensive computation on an automatic refresh but do it when the
/// operator asked.
public enum RefreshReason: String, Sendable, CaseIterable {
    case launch
    case interval
    case manual
}

/// Whether the panel is currently drawn light or dark. Passed to producers so a
/// card can pick colours that work, without each one guessing.
public enum Appearance: String, Sendable, CaseIterable {
    case light
    case dark

    /// What uDeck tells a producer about how its card will be drawn.
    ///
    /// Always dark, because the panel is: it hangs over whatever the operator
    /// has on screen, so its legibility cannot follow the system. A constant
    /// rather than a variable nothing writes — and the plugin contract says
    /// the same thing instead of listing two values as if they varied.
    public static let panel: Appearance = .dark
}

/// The environment a plugin's processes run in — a producer's and a card
/// action's — built here and nowhere else, for uDeck and for
/// `udeck-plugin run` alike: a producer an author runs in a terminal is handed
/// exactly the variables the panel would hand it.
///
/// Built from scratch rather than inherited. uDeck can be launched from
/// Finder, from a shell or by launchd, each with a different environment,
/// and a plugin that works when started one way and not another is close to
/// impossible to debug. Building it explicitly also means a third-party
/// plugin never sees whatever secrets happen to be in the launching shell.
///
/// What only the host knows comes in as arguments: the home folder, and the
/// temporary folder it was itself given, if any.
public enum PluginEnvironment {
    /// Where a bare `run[0]`, and a bare action command, is looked up unless the
    /// operator has said otherwise: uDeck's `pluginExecutableSearchPath`
    /// starts as this.
    public static let defaultSearchPath = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// The environment a producer runs in.
    public static func producer(
        manifest: PluginManifest,
        directory: URL,
        settings: PluginSettings,
        cacheDirectory: URL,
        searchPath: [String],
        appearance: Appearance,
        reason: RefreshReason,
        language: String,
        home: String,
        temporaryDirectory: String?
    ) -> [String: String] {
        var environment: [String: String] = [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": home,
            // Producers print human text; without a UTF-8 locale a runtime can
            // fall back to ASCII and mangle everything non-Latin.
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "UDECK_API": String(PluginAPI.current),
            "UDECK_PLUGIN_ID": manifest.id.rawValue,
            "UDECK_PLUGIN_DIR": directory.path,
            "UDECK_CACHE_DIR": cacheDirectory.path,
            "UDECK_APPEARANCE": appearance.rawValue,
            "UDECK_REFRESH_REASON": reason.rawValue,
            // The language the panel is speaking, so a producer can answer in
            // it. `LANG` and `LC_ALL` above stay pinned to a UTF-8 locale and
            // are not this: they exist so a runtime prints UTF-8 rather than
            // mangling anything non-Latin, and changing them to carry the
            // language would put that guarantee at the mercy of which locales
            // happen to be generated on the machine.
            "UDECK_LANG": language,
        ]
        if let temporaryDirectory { environment["TMPDIR"] = temporaryDirectory }
        environment.merge(settings.environment(for: manifest)) { _, new in new }
        return environment
    }

    /// The environment a card's action runs in.
    ///
    /// Deliberately the same shape as a producer's: a known search path, a
    /// UTF-8 locale, and nothing else carried over from however uDeck happened
    /// to be started — but fewer of the `UDECK_` variables: an action is a
    /// command the operator pressed, not a run that answers with a card. Each
    /// of them is part of the plugin contract, and the release registry
    /// `minUDeck` is worked out from dates each of them
    /// (`ContractFeature.actionEnvironment`).
    public static func action(
        id: PluginIdentifier,
        directory: URL?,
        searchPath: [String],
        home: String,
        temporaryDirectory: String?
    ) -> [String: String] {
        var environment: [String: String] = [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "UDECK_API": String(PluginAPI.current),
            "UDECK_PLUGIN_ID": id.rawValue,
        ]
        if let directory {
            environment["UDECK_PLUGIN_DIR"] = directory.path
        }
        if let temporaryDirectory { environment["TMPDIR"] = temporaryDirectory }
        return environment
    }
}
