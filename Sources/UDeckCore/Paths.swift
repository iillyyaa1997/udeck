import Foundation
import UDeckPluginFormat

/// Where uDeck's folder is on this machine. The layout inside it is the
/// format's (`UDeckPaths`, in `UDeckPluginFormat`); which folder it is, uDeck
/// decides — from its own environment, as it always has.
extension UDeckPaths {
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
}
