#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The operator's answer to one plugin's request.
public struct PluginGrant: Codable, Equatable, Sendable {
    public var granted: Set<Capability>
    public var denied: Set<Capability>

    /// The manifest version the decision was made against. When a plugin
    /// updates and asks for more, the operator is asked again rather than
    /// silently inheriting the old answer.
    public var decidedForVersion: String

    /// The tree the plugin's folder hashed to when the decision was made —
    /// git's id for the folder, the way uDeck hashes it — for code nobody
    /// verified: a branch or a pull request, whose content changes under the
    /// same version without anybody reviewing it. Such a decision holds only
    /// for exactly that content (`PermissionGate`'s `requiredTree`). Absent
    /// for a decision held to the version alone, and from every decision
    /// written before there was such code; read back, those hold for no tree.
    public var decidedForTree: String?

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
        decidedForTree: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.granted = granted
        self.denied = denied
        self.decidedForVersion = decidedForVersion
        self.decidedForTree = decidedForTree
        self.decidedAt = Date(timeIntervalSince1970: decidedAt.timeIntervalSince1970.rounded(.down))
    }

    /// Whether this decision is the one for `version` — and, when a tree is
    /// required (`PermissionGate`), for exactly that tree too. An empty tree
    /// is a folder not hashed yet, and no decision holds for it.
    public func holds(forVersion version: String, tree requiredTree: String?) -> Bool {
        guard decidedForVersion == version else { return false }
        guard let requiredTree else { return true }
        return !requiredTree.isEmpty && decidedForTree == requiredTree
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
    /// for since they were. Nothing pending is a plugin that asks for nothing
    /// and whose code nobody verified: it is asked whether it may run at all.
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
    /// The tree to require of a folder whose decision is held to its tree
    /// and which has not been hashed yet: no decision holds for it, so the
    /// plugin waits until it is (`PluginGrant.holds`).
    public static let treeNotHashedYet = ""

    /// May this plugin be launched at all?
    ///
    /// This is the enforcement that is genuinely real for a plugin's own
    /// process: it either runs with everything it declared, or it does not run.
    /// Launching a plugin with half its declared capabilities refused would be
    /// theatre — nothing would actually stop it from doing the rest.
    ///
    /// `requiredTree` is for code nobody verified — a branch, a pull request —
    /// and is the tree its folder hashes to now (`treeNotHashedYet` until it
    /// is hashed). Given, a decision counts only when it was made for exactly
    /// that tree, and a plugin that asks for nothing is asked about too
    /// (`awaitingDecision` with nothing pending): its code changes without
    /// anybody reviewing it, and nothing else stands between it and the
    /// operator's machine. Nil — a verified plugin, a folder of the
    /// operator's own, a linked working copy, `udeck-plugin run` — and the
    /// decision is held to the version, as it always was. A required tree
    /// only ever asks for more: nothing that is allowed without one is
    /// allowed by one that is not.
    public static func launchDecision(
        for manifest: PluginManifest,
        grant: PluginGrant?,
        enabled: Bool,
        requiredTree: String? = nil
    ) -> LaunchDecision {
        guard enabled else { return .disabled }

        let requested = manifest.permissions.capabilities
        guard !requested.isEmpty || requiredTree != nil else { return .allowed }

        guard let grant, grant.holds(forVersion: manifest.version, tree: requiredTree) else {
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
    ///
    /// The matching is deliberately strict, and it used to be too loose. It
    /// compared only the last path component, so a grant for `ps` — which the
    /// operator read as "may run the `ps` on this machine" — also permitted
    /// `/tmp/anything/ps`. No privilege was gained by that, since the plugin's
    /// own process can run whatever it likes; what was wrong is that the
    /// consent sheet said something untrue, and a permission screen that
    /// overstates itself is worse than none.
    ///
    /// So: a bare name matches a grant for that name, and a path matches only a
    /// grant for exactly that path. A plugin that wants to run its own bundled
    /// tool has to say so, and the operator gets to see the path they are
    /// agreeing to.
    ///
    /// The *current* manifest has to ask for it too, and the grant has to have
    /// been decided for the version now on disk — the same two conditions
    /// `launchDecision` applies. Without them a grant outlived what it was
    /// given for: version 1 asked for `exec: ["open"]` and got it, version 2
    /// replaced it asking for nothing, and the permission screen said the
    /// plugin asks for nothing while its buttons still ran `open`. With a
    /// `requiredTree`, as for `launchDecision`, it has to have been decided
    /// for exactly that tree as well.
    public static func mayRun(
        _ action: CardAction,
        requestedBy manifest: PluginManifest,
        grant: PluginGrant?,
        requiredTree: String? = nil
    ) -> Bool {
        guard let executable = action.run.first, !executable.isEmpty else { return false }
        guard let grant, grant.holds(forVersion: manifest.version, tree: requiredTree) else { return false }
        let capability = Capability.exec(executable)
        guard manifest.permissions.capabilities.contains(capability) else { return false }
        return grant.granted.contains(capability)
    }
}
