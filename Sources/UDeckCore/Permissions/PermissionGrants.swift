import Foundation

/// The operator's answer to one plugin's request.
public struct PluginGrant: Codable, Equatable, Sendable {
    public var granted: Set<Capability>
    public var denied: Set<Capability>

    /// The manifest version the decision was made against. When a plugin
    /// updates and asks for more, the operator is asked again rather than
    /// silently inheriting the old answer.
    public var decidedForVersion: String

    /// Truncated to whole seconds.
    ///
    /// The file this is stored in uses ISO-8601 timestamps, which carry no
    /// sub-second part; keeping the extra precision in memory would make a
    /// grant stop comparing equal to the same grant read back from disk, and
    /// that difference would show up as a spurious "the plugin changed" prompt.
    public var decidedAt: Date

    public init(
        granted: Set<Capability> = [],
        denied: Set<Capability> = [],
        decidedForVersion: String,
        decidedAt: Date = Date()
    ) {
        self.granted = granted
        self.denied = denied
        self.decidedForVersion = decidedForVersion
        self.decidedAt = Date(timeIntervalSince1970: decidedAt.timeIntervalSince1970.rounded(.down))
    }
}

/// Every decision the operator has made, for every plugin.
public struct PermissionGrants: Codable, Equatable, Sendable {
    public var version: Int
    public var byPlugin: [String: PluginGrant]

    public init(version: Int = 1, byPlugin: [String: PluginGrant] = [:]) {
        self.version = version
        self.byPlugin = byPlugin
    }

    public subscript(id: PluginIdentifier) -> PluginGrant? {
        get { byPlugin[id.rawValue] }
        set { byPlugin[id.rawValue] = newValue }
    }
}

/// Whether a plugin may run, and why not when it may not.
public enum LaunchDecision: Equatable, Sendable {
    case allowed

    /// The operator has not been asked yet, or the plugin changed what it asks
    /// for since they were.
    case awaitingDecision(pending: [Capability])

    /// The operator refused something the plugin declared it needs.
    case refused(denied: [Capability])

    /// The plugin is switched off.
    case disabled

    public var isAllowed: Bool { self == .allowed }
}

/// The one place that decides what a plugin is allowed to do.
///
/// See `CapabilityEnforcement` for what "allowed" can and cannot mean here.
public enum PermissionGate {
    /// May this plugin be launched at all?
    ///
    /// This is the enforcement that is genuinely real for a plugin's own
    /// process: it either runs with everything it declared, or it does not run.
    /// Launching a plugin with half its declared capabilities refused would be
    /// theatre — nothing would actually stop it from doing the rest.
    public static func launchDecision(
        for manifest: PluginManifest,
        grant: PluginGrant?,
        enabled: Bool
    ) -> LaunchDecision {
        guard enabled else { return .disabled }

        let requested = manifest.permissions.capabilities
        guard !requested.isEmpty else { return .allowed }

        guard let grant, grant.decidedForVersion == manifest.version else {
            return .awaitingDecision(pending: requested)
        }

        let refused = requested.filter { grant.denied.contains($0) }
        if !refused.isEmpty { return .refused(denied: refused) }

        let undecided = requested.filter { !grant.granted.contains($0) }
        if !undecided.isEmpty { return .awaitingDecision(pending: undecided) }

        return .allowed
    }

    /// May the host run this card action on the plugin's behalf?
    ///
    /// Genuinely enforced: the host owns the process, so a plugin that was never
    /// granted `exec` for this command gets nothing, whatever its card says.
    /// The command is matched by its last path component, so a plugin cannot
    /// smuggle `/usr/bin/ps` past a grant for `kubectl`.
    public static func mayRun(_ action: CardAction, grant: PluginGrant?) -> Bool {
        guard let executable = action.run.first, !executable.isEmpty else { return false }
        guard let grant else { return false }
        let name = (executable as NSString).lastPathComponent
        return grant.granted.contains(.exec(name)) || grant.granted.contains(.exec(executable))
    }

    /// May the host hand this plugin the named secret?
    public static func mayReceiveSecret(_ name: String, grant: PluginGrant?) -> Bool {
        grant?.granted.contains(.secret(name)) ?? false
    }
}
