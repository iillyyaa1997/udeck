#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The temporary folder this process was given: `TMPDIR` when it is set, and
/// the system's when it is not.
///
/// On a Mac, Foundation answers the system's whatever `TMPDIR` says:
/// `FileManager.default.temporaryDirectory` and `NSTemporaryDirectory()` both
/// gave the account's folder under `/var/folders` with `TMPDIR` pointing
/// somewhere else (measured on macOS 27 with Swift 6.4, 2026-10-16), so a run
/// told where to keep its temporary files — a CI job's, a test run's, a
/// person's — kept them under `/var/folders` all the same. Everything
/// `udeck-plugin` and uDeck make in a temporary folder, and the folder they
/// hand a plugin, is this one.
public enum TemporaryFolder {
    /// The folder, `given` being `TMPDIR` as the process has it: that, as it is
    /// written — a plugin is handed exactly what uDeck was — when it names a
    /// folder by its full path, and the system's otherwise: unset, empty, or a
    /// relative path, which names a different folder from every working
    /// directory. A path made in it is made through `url`, which a `/` at the
    /// end changes nothing for.
    public static func path(given: String?) -> String {
        guard let given, given.hasPrefix("/") else { return system }
        return given
    }

    /// The folder, from this process's own `TMPDIR`.
    public static var path: String {
        path(given: getenv("TMPDIR").map { String(cString: $0) })
    }

    /// The same, as a folder's URL.
    public static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The system's: what Foundation answers.
    static var system: String {
        FileManager.default.temporaryDirectory.path
    }
}
