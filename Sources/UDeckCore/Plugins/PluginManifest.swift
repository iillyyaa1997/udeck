import Foundation

/// The contract version this build of uDeck speaks.
///
/// A manifest declaring a higher `api` is refused rather than guessed at: a
/// plugin written against a future contract may rely on behaviour this build
/// does not have, and running it half-understood is worse than not running it.
/// A manifest declaring a lower `api` keeps working — that is the promise the
/// number exists to make.
public enum PluginAPI {
    public static let current = 1
    public static let oldestSupported = 1
}

/// How the host runs a plugin.
public enum PluginKind: String, Codable, Sendable, CaseIterable {
    /// Executed on an interval; prints one card to stdout and exits.
    ///
    /// The host owns the deadline. A producer cannot time itself out — there is
    /// no `timeout(1)` on a stock macOS — so a hung producer that was trusted to
    /// police itself would freeze its card on a stale value forever.
    case poll

    /// Long-lived, owns a live surface. The host owns spawn, health, restart and
    /// stop.
    ///
    /// Not implemented in this version. It is described in the manifest format
    /// from the start anyway: adding it later would otherwise force a breaking
    /// change to a format other people's plugins already depend on.
    case resident
}

/// What a `resident` plugin should do when it exits.
public struct RestartPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case always
        case onFailure = "on-failure"
        case never
    }

    public var mode: Mode
    public var initialBackoff: TimeInterval
    public var maximumBackoff: TimeInterval
    public var backoffFactor: Double

    public init(
        mode: Mode = .onFailure,
        initialBackoff: TimeInterval = 1,
        maximumBackoff: TimeInterval = 60,
        backoffFactor: Double = 2
    ) {
        self.mode = mode
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.backoffFactor = backoffFactor
    }
}

/// Size hints for the window a plugin's card lands in, in grid cells.
public struct WindowHints: Codable, Equatable, Sendable {
    public var defaultWidth: Int
    public var defaultHeight: Int
    public var minimumWidth: Int
    public var minimumHeight: Int

    public init(defaultWidth: Int = 4, defaultHeight: Int = 3,
                minimumWidth: Int = 2, minimumHeight: Int = 1) {
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
    }

    private enum CodingKeys: String, CodingKey {
        case defaultWidth, defaultHeight, minimumWidth = "minWidth", minimumHeight = "minHeight"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowHints()
        self.init(
            defaultWidth: try c.decodeIfPresent(Int.self, forKey: .defaultWidth) ?? d.defaultWidth,
            defaultHeight: try c.decodeIfPresent(Int.self, forKey: .defaultHeight) ?? d.defaultHeight,
            minimumWidth: try c.decodeIfPresent(Int.self, forKey: .minimumWidth) ?? d.minimumWidth,
            minimumHeight: try c.decodeIfPresent(Int.self, forKey: .minimumHeight) ?? d.minimumHeight
        )
    }
}

/// `manifest.json`, as written by a plugin author.
public struct PluginManifest: Codable, Equatable, Sendable {
    public var id: PluginIdentifier
    public var name: String
    public var version: String
    public var api: Int
    public var kind: PluginKind
    public var description: String?
    public var author: String?
    public var homepage: String?

    /// The command to run, as an argument vector. Never a shell string: a shell
    /// string has quoting rules, and quoting rules have injection bugs.
    ///
    /// A relative `run[0]` is resolved against the plugin's own folder, so a
    /// plugin can ship its own executable without knowing where it was installed.
    public var run: [String]

    /// Seconds between runs, for `poll`.
    public var interval: TimeInterval?

    /// Seconds a single run may take before the host kills it, for `poll`.
    public var timeout: TimeInterval?

    /// Restart behaviour, for `resident`.
    public var restart: RestartPolicy?

    public var permissions: PermissionRequest
    public var settings: [SettingDeclaration]
    public var window: WindowHints

    private enum CodingKeys: String, CodingKey {
        case id, name, version, api, kind, description, author, homepage
        case run, interval, timeout, restart, permissions, settings, window
    }

    public init(
        id: PluginIdentifier,
        name: String,
        version: String,
        api: Int = PluginAPI.current,
        kind: PluginKind,
        description: String? = nil,
        author: String? = nil,
        homepage: String? = nil,
        run: [String],
        interval: TimeInterval? = nil,
        timeout: TimeInterval? = nil,
        restart: RestartPolicy? = nil,
        permissions: PermissionRequest = PermissionRequest(),
        settings: [SettingDeclaration] = [],
        window: WindowHints = WindowHints()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.api = api
        self.kind = kind
        self.description = description
        self.author = author
        self.homepage = homepage
        self.run = run
        self.interval = interval
        self.timeout = timeout
        self.restart = restart
        self.permissions = permissions
        self.settings = settings
        self.window = window
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(PluginIdentifier.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            version: try c.decode(String.self, forKey: .version),
            api: try c.decode(Int.self, forKey: .api),
            kind: try c.decode(PluginKind.self, forKey: .kind),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            author: try c.decodeIfPresent(String.self, forKey: .author),
            homepage: try c.decodeIfPresent(String.self, forKey: .homepage),
            run: try c.decode([String].self, forKey: .run),
            interval: try c.decodeIfPresent(TimeInterval.self, forKey: .interval),
            timeout: try c.decodeIfPresent(TimeInterval.self, forKey: .timeout),
            restart: try c.decodeIfPresent(RestartPolicy.self, forKey: .restart),
            permissions: try c.decodeIfPresent(PermissionRequest.self, forKey: .permissions) ?? PermissionRequest(),
            settings: try c.decodeIfPresent([SettingDeclaration].self, forKey: .settings) ?? [],
            window: try c.decodeIfPresent(WindowHints.self, forKey: .window) ?? WindowHints()
        )
    }
}

/// Something wrong with a manifest, in terms an author can act on.
public enum ManifestProblem: Equatable, Sendable, CustomStringConvertible {
    case unsupportedAPI(declared: Int, supported: ClosedRange<Int>)
    case emptyRunCommand
    case missingInterval
    case nonPositiveInterval(TimeInterval)
    case missingTimeout
    case nonPositiveTimeout(TimeInterval)
    case durationOutOfRange(field: String, value: TimeInterval, maximum: TimeInterval)
    case timeoutNotShorterThanInterval(timeout: TimeInterval, interval: TimeInterval)
    case residentNotSupportedYet
    case blankName
    case duplicateSettingKey(String)
    case invalidSettingDeclaration(key: String, reason: String)
    case invalidWindowHints(reason: String)

    public var description: String {
        switch self {
        case .unsupportedAPI(let declared, let supported):
            "manifest declares api \(declared); this build of uDeck speaks \(supported.lowerBound)…\(supported.upperBound)"
        case .emptyRunCommand:
            "\"run\" must contain at least the command to execute"
        case .missingInterval:
            "a poll plugin must declare \"interval\" in seconds"
        case .nonPositiveInterval(let value):
            "\"interval\" must be greater than zero, got \(value)"
        case .missingTimeout:
            "a poll plugin must declare \"timeout\" in seconds"
        case .nonPositiveTimeout(let value):
            "\"timeout\" must be greater than zero, got \(value)"
        case .durationOutOfRange(let field, let value, let maximum):
            "\"\(field)\" is \(value) seconds, past the \(Int(maximum))-second limit — a plausible typo, and a number that large has no sensible meaning here"
        case .timeoutNotShorterThanInterval(let timeout, let interval):
            "\"timeout\" (\(timeout)s) must be shorter than \"interval\" (\(interval)s), otherwise a slow run always overlaps the next one"
        case .residentNotSupportedYet:
            "\"kind\": \"resident\" is described by the manifest format but not implemented in this version"
        case .blankName:
            "\"name\" must not be blank — it is what the operator sees"
        case .duplicateSettingKey(let key):
            "two settings share the key \"\(key)\""
        case .invalidSettingDeclaration(let key, let reason):
            "setting \"\(key)\": \(reason)"
        case .invalidWindowHints(let reason):
            "\"window\": \(reason)"
        }
    }
}

extension PluginManifest {
    /// Everything wrong with this manifest. Empty means it is usable.
    ///
    /// Returns all the problems rather than the first one: an author fixing a
    /// manifest should not have to discover its faults one launch at a time.
    public func problems(gridColumns: Int = DeckLayout.defaultColumns) -> [ManifestProblem] {
        var found: [ManifestProblem] = []

        let supported = PluginAPI.oldestSupported ... PluginAPI.current
        if !supported.contains(api) {
            found.append(.unsupportedAPI(declared: api, supported: supported))
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(.blankName)
        }
        if run.isEmpty || run[0].trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(.emptyRunCommand)
        }

        switch kind {
        case .poll:
            switch interval {
            case .none: found.append(.missingInterval)
            case .some(let value) where value <= 0 || !value.isFinite:
                found.append(.nonPositiveInterval(value))
            case .some(let value) where value > Seconds.ceiling:
                // Unbounded durations are not a taste question: they are turned
                // into nanoseconds, and past about 585 years that conversion
                // traps and takes the process with it. The conversion saturates
                // now, but a manifest that means something impossible should be
                // told so rather than quietly given a different number.
                found.append(.durationOutOfRange(field: "interval", value: value, maximum: Seconds.ceiling))
            default: break
            }
            switch timeout {
            case .none: found.append(.missingTimeout)
            case .some(let value) where value <= 0 || !value.isFinite:
                found.append(.nonPositiveTimeout(value))
            case .some(let value) where value > Seconds.ceiling:
                found.append(.durationOutOfRange(field: "timeout", value: value, maximum: Seconds.ceiling))
            default: break
            }
            if let interval, let timeout, interval > 0, timeout > 0, timeout >= interval {
                found.append(.timeoutNotShorterThanInterval(timeout: timeout, interval: interval))
            }
        case .resident:
            found.append(.residentNotSupportedYet)
        }

        var seenKeys = Set<String>()
        for declaration in settings {
            if !seenKeys.insert(declaration.key).inserted {
                found.append(.duplicateSettingKey(declaration.key))
            }
            if let reason = declaration.problem {
                found.append(.invalidSettingDeclaration(key: declaration.key, reason: reason))
            }
        }

        if window.defaultWidth < 1 || window.defaultWidth > gridColumns {
            found.append(.invalidWindowHints(reason: "defaultWidth must be between 1 and \(gridColumns)"))
        }
        if window.minimumWidth < 1 || window.minimumWidth > window.defaultWidth {
            found.append(.invalidWindowHints(reason: "minWidth must be between 1 and defaultWidth"))
        }
        if window.defaultHeight < 1 {
            found.append(.invalidWindowHints(reason: "defaultHeight must be at least 1"))
        }
        if window.minimumHeight < 1 || window.minimumHeight > window.defaultHeight {
            found.append(.invalidWindowHints(reason: "minHeight must be between 1 and defaultHeight"))
        }

        return found
    }
}
