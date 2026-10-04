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

/// Where this machine's accounts keep their home folders, as the system's
/// account database says — which is where uDeck finds its own.
///
/// Foundation's `NSHomeDirectory()`, which uDeck finds `~/.udeck` with and
/// hands its producers as `HOME`, takes `CFFIXED_USER_HOME` when it is set,
/// then the account database, and `HOME` only when the database has no entry
/// for the account (`account(in:)`). `~name` — `NSString.expandingTildeInPath`,
/// which uDeck reads `UDECK_HOME` with — is `CFFIXED_USER_HOME` again when that
/// is set, and the account `name`'s entry otherwise (`account(named:in:)`).
/// That is swift-foundation's `String.homeDirectoryPath()` and
/// `homeDirectoryPath(forUser:)`, in String+Path.swift.
///
/// A value rather than two functions so that a test can name homes of its
/// own: `udeck-plugin link` makes a link in the folder this answers, and a
/// test that reached the real account's would make one in the operator's
/// `~/.udeck`.
public struct UserHomes: Sendable {
    /// The home folder of the account running this, or nil when the account
    /// database has none for it.
    public var current: @Sendable () -> String?

    /// The home folder of the account called `name`, or nil when there is no
    /// such account.
    public var named: @Sendable (_ name: String) -> String?

    public init(current: @escaping @Sendable () -> String?, named: @escaping @Sendable (String) -> String?) {
        self.current = current
        self.named = named
    }

    /// The machine's own account database.
    public static let system = UserHomes(
        current: {
            // The effective account, as Foundation takes it — but the real one
            // when the effective one is root: a process that called
            // `seteuid(0)` is still its user's, and its home is theirs.
            let effective = geteuid()
            return home(uid: effective == 0 ? getuid() : effective)
        },
        named: { name in home(name: name) }
    )

    /// The home folder of the account running this, as uDeck's Foundation
    /// answers `NSHomeDirectory()` in `environment`: `CFFIXED_USER_HOME`, then
    /// the account database, then `HOME` — each only when it is not empty.
    /// Nil when there is none of the three.
    public func account(in environment: [String: String]) -> String? {
        Self.given("CFFIXED_USER_HOME", in: environment) ?? current() ?? Self.given("HOME", in: environment)
    }

    /// The home folder `~name` means in `environment`, as Foundation expands
    /// it: `CFFIXED_USER_HOME` when it is set — for any name — and the
    /// account `name`'s otherwise. Nil when there is no such account.
    public func account(named name: String, in environment: [String: String]) -> String? {
        Self.given("CFFIXED_USER_HOME", in: environment) ?? named(name)
    }

    /// The variable `name` of `environment`, unless it is empty: an empty
    /// home folder, or an empty `UDECK_HOME`, names none.
    public static func given(_ name: String, in environment: [String: String]) -> String? {
        environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The home folder `getpwuid_r` gives `uid`.
    static func home(uid: uid_t) -> String? {
        lookUp { entry, buffer, size, found in getpwuid_r(uid, &entry, buffer, size, &found) }
    }

    /// The home folder `getpwnam_r` gives `name`.
    static func home(name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return lookUp { entry, buffer, size, found in getpwnam_r(name, &entry, buffer, size, &found) }
    }

    /// One reentrant look-up in the account database, with a buffer as large
    /// as the system says one entry can need, and larger while it says that
    /// was not enough.
    private static func lookUp(
        _ call: (inout passwd, UnsafeMutablePointer<CChar>, Int, inout UnsafeMutablePointer<passwd>?) -> Int32
    ) -> String? {
        var size = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        if size <= 0 { size = 4096 }
        while size <= 1 << 20 {
            var entry = passwd()
            var found: UnsafeMutablePointer<passwd>?
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
            defer { buffer.deallocate() }
            let failed = call(&entry, buffer, size, &found)
            if failed == ERANGE {
                size *= 2
                continue
            }
            guard failed == 0, found != nil, let directory = entry.pw_dir else { return nil }
            let home = String(cString: directory)
            return home.isEmpty ? nil : home
        }
        return nil
    }
}
