/// How much of the format a check holds a repository to.
///
/// Three layers, each the one before and more (docs/plugin-repository.md, "What
/// a folder may contain" and "The official repository"):
///
/// * **Installable** — what uDeck itself refuses, by the very code uDeck runs
///   when it lists a catalogue and installs: the passport, rules 1 and 3–8,
///   and LFS pointers from rule 9. A repository that passes this installs.
/// * **Strict** — also what makes a plugin hard to review or likely to break,
///   which uDeck only ignores: rules 2, the archive attributes of 9, 10–13,
///   `minUDeck` against what the plugin uses (19), unknown fields in the
///   passport, and JSON read strictly — no field twice, no byte order mark, a
///   whole number written as one.
/// * **Official** — also the official repository's own rules: 14–16, and 17,
///   the sign-offs, when there is a base and a head to take commits between.
///
/// The version check (18) runs in every layer whenever there is a base to
/// compare with: it is what makes "changed, but still 1.2.0" impossible, and
/// no repository is better off without that.
public struct CheckMode: Sendable, Equatable {
    public var strict: Bool
    public var official: Bool

    public init(strict: Bool = false, official: Bool = false) {
        self.strict = strict || official
        self.official = official
    }

    public static let installable = CheckMode()
    public static let strict = CheckMode(strict: true)
    public static let official = CheckMode(official: true)
}

/// One thing a check found: where, which rule, and what is wrong, in words an
/// author can act on.
public struct CheckFinding: Sendable, Equatable, CustomStringConvertible {
    public enum Level: String, Sendable {
        /// Fails the check.
        case error
        /// Said, and the check still passes.
        case warning
    }

    public var level: Level
    /// `passport`, or a rule's number.
    public var rule: String
    /// Where in the repository, or `commit <sha>` for rule 17.
    public var path: String
    public var message: String

    public init(level: Level, rule: String, path: String, message: String) {
        self.level = level
        self.rule = rule
        self.path = path
        self.message = message
    }

    /// `error: plugins/uptime/README.md: is missing; … [rule 10]` — the line
    /// the Python check printed, word for word in its shape.
    public var description: String {
        let label = rule == CheckRule.passport ? "passport" : "rule \(rule)"
        let place = path.isEmpty ? "" : "\(path): "
        return "\(level.rawValue): \(place)\(message) [\(label)]"
    }
}

/// The rules' names as findings carry them.
public enum CheckRule {
    public static let passport = "passport"
    /// The version goes up whenever the folder changed.
    public static let versionBump = "18"
    /// `minUDeck` is not below what the plugin uses.
    public static let minimumUDeck = "19"
}

/// Everything a check found, and what it looked at.
public struct CheckReport: Sendable {
    public var findings: [CheckFinding] = []
    /// The commit that was read, or nil for a folder read from disk.
    public var commit: String?
    /// Folders directly under `plugins/` — the plugin folders there are,
    /// whether their names are plugin ids or not.
    public var pluginFolders = 0
    /// Notes about how the check read what it read — never a finding.
    public var notes: [String] = []

    public init() {}

    public var errors: [CheckFinding] { findings.filter { $0.level == .error } }
    public var warnings: [CheckFinding] { findings.filter { $0.level == .warning } }

    mutating func error(_ rule: String, _ path: String, _ message: String) {
        findings.append(CheckFinding(level: .error, rule: rule, path: path, message: message))
    }

    mutating func warning(_ rule: String, _ path: String, _ message: String) {
        findings.append(CheckFinding(level: .warning, rule: rule, path: path, message: message))
    }
}

/// The check could not be made at all — git is missing, a commit is not there.
/// Not the same thing as a repository that fails it.
public struct CheckFailure: Error, Sendable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
