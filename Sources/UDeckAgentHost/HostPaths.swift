import Foundation

/// Names a uDeck and its helper agree on. Both work them out from the
/// application's bundle identifier, so the release and a debug build
/// (`place.unicorns.udeck.debug`) each have a helper of their own and never
/// reach each other's.
public enum HostPaths {
    /// The helper's launchd label, its Mach service, its code identifier, and
    /// the name of its plist in `Contents/Library/LaunchAgents` — all one, as
    /// `Scripts/make-app.sh` writes them.
    public static func agentLabel(bundleIdentifier: String) -> String {
        bundleIdentifier + ".agentd"
    }

    /// The user's real home folder, from the user database rather than
    /// `$HOME`, which a launchd job or a test may have set to anything.
    public static var home: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
}
