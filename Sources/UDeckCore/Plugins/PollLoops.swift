import Foundation

/// One plugin's poll loop as it was started: what it runs and under which
/// decision, for as long as it runs. A loop sleeps the plugin's interval and
/// runs it, over and over; started again, it sleeps the whole interval first.
public struct PollLoop: Equatable, Sendable {
    /// The plugin as the plugins folder was read: its folder — for a linked
    /// folder, where the link led — its manifest, interval and command. The
    /// loop runs this, and nothing read later, until it is started again.
    public var plugin: DiscoveredPlugin
    /// The operator's decision it runs under.
    public var grant: PluginGrant?

    public init(plugin: DiscoveredPlugin, grant: PluginGrant?) {
        self.plugin = plugin
        self.grant = grant
    }
}

/// Which plugins have a poll loop, and which loops a change starts again.
///
/// The plugins folder is read again whenever something in it changes — and in
/// any folder a linked plugin's link leads to, which is an author's working
/// copy: an editor saving, a build, `git` writing into `.git`. Every read used
/// to start every loop again, and a loop started again sleeps its whole
/// interval before it runs: a working copy touched every three seconds kept
/// every plugin with a longer interval — the one being written and every other
/// on the panel — from running on its interval at all, and their cards went
/// stale while the panel was open.
///
/// So a loop is started again only when what it runs changed: the plugin's
/// folder, its manifest, its command, or the operator's decision. A plugin
/// whose manifest was edited is started again at once, with the new one; the
/// rest keep their rhythm. What a run reads when it starts — the values of its
/// settings, the language, the search path handed to it as `PATH` — is read
/// then, and needs no new loop.
public enum PollLoops {
    /// The loops that should be running now, by plugin id: every `poll` plugin
    /// placed on a tab, allowed, not being quieted, with an interval — and none
    /// at all while nothing is polled (`polling`: the panel out of sight, and
    /// polling while collapsed off).
    public static func wanted(
        _ plugins: [DiscoveredPlugin],
        placed: Set<PluginIdentifier>,
        grants: PermissionGrants,
        settings: PluginSettings,
        polling: Bool,
        isQuiet: (String) -> Bool
    ) -> [String: PollLoop] {
        guard polling else { return [:] }
        var loops: [String: PollLoop] = [:]
        for plugin in plugins {
            guard let manifest = plugin.manifest, manifest.kind == .poll,
                  !isQuiet(manifest.id.rawValue),
                  placed.contains(manifest.id),
                  PermissionGate.launchDecision(for: manifest, grant: grants[manifest.id],
                                                enabled: settings.isEnabled(manifest.id)).isAllowed,
                  let interval = manifest.interval, interval > 0
            else { continue }
            loops[manifest.id.rawValue] = PollLoop(plugin: plugin, grant: grants[manifest.id])
        }
        return loops
    }

    /// What to do about the loops running, given the ones wanted.
    public struct Plan: Equatable, Sendable {
        /// Loops to end: no longer wanted, or wanted as something else.
        public var stop: Set<String>
        /// Loops to start: wanted, and not running as they are wanted. Every
        /// other running loop is left as it is, its next run when it was due.
        public var start: Set<String>

        public init(stop: Set<String> = [], start: Set<String> = []) {
            self.stop = stop
            self.start = start
        }
    }

    /// Stops what is not wanted as it runs, and starts what is wanted and not
    /// running so. `again` starts every wanted loop afresh — what the panel
    /// coming into sight does, right after it ran every plugin once.
    public static func plan(running: [String: PollLoop], wanted: [String: PollLoop], again: Bool = false) -> Plan {
        if again { return Plan(stop: Set(running.keys), start: Set(wanted.keys)) }
        var plan = Plan()
        for (id, loop) in running where wanted[id] != loop { plan.stop.insert(id) }
        for (id, loop) in wanted where running[id] != loop { plan.start.insert(id) }
        return plan
    }
}
