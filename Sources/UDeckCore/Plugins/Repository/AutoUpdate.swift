import Foundation

/// Which verified plugins update themselves after a read of the catalogue, and
/// why each other one does not — decided here, whole, where it is tested.
/// uDeck asks this of every installed plugin after each successful read of the
/// catalogue, and does what it says one plugin at a time, through the same
/// update **Update** makes.
///
/// A plugin updates itself only when everything below holds; anything else,
/// and the row offers the update as it always has, for the operator to press:
///
/// * **Update verified plugins by themselves** is on, and the copy's source can
///   be read — for the official one, **Official catalogue** on (off, uDeck makes
///   no request to the official repository) — as `switchedOn` says;
/// * the head has a newer version, or the same version with other files
///   (`UpdateOffer.isWaiting`) — never an older one, one that cannot run here,
///   or none;
/// * the copy on disk stands **Verified**: installed from the default branch of
///   the official repository, and still exactly what was merged there;
/// * the operator did not choose this version over the newest (`pinned`);
/// * the new version asks for exactly what the copy on disk asks for, byte for
///   byte (`asksDifferently`) — a change of permissions is the operator's to
///   agree to, and stays an offer;
/// * nothing of the operator's is at the plugin's place, or would go to the
///   Trash — a `.env`, a link — by the rule every button that replaces a
///   folder warns by (`OperatorsWork`): an update by itself cannot warn;
/// * it has not failed since the last read of the catalogue: a failed update
///   by itself is said on the row, and tried again at the next read.
///
/// And it waits — the minute's tick asks again — while one of the plugin's card
/// actions is running, which an update by itself never ends, or while another
/// install, update or removal is.
public enum AutoUpdate {
    /// What one installed plugin comes to.
    public enum Verdict: Equatable, Sendable {
        /// It updates itself now, to `version`.
        case update(version: String)
        /// Not by itself, for `reason`: the row says what it says without it.
        case not(Reason)
        /// Not yet: asked again on the minute's tick.
        case later(Wait)
    }

    /// Why a plugin does not update itself.
    public enum Reason: Equatable, Sendable {
        /// The switch, or the official catalogue, is off.
        case switchedOff
        /// The head has nothing for it to update to: it is current, the
        /// repository went back, the new version cannot run here, the folder
        /// is gone from the repository — or there is no catalogue.
        case nothingWaiting
        /// The copy on disk is not **Verified**: changed on disk, missing, a
        /// folder of the operator's own, a linked folder, or not hashed yet.
        case notVerified
        /// The operator chose this version.
        case pinned
        /// The new version asks for something else, or what either asks for
        /// could not be read.
        case asksDifferently
        /// Something of the operator's is at the plugin's place, or a link:
        /// replacing it warns first.
        case operatorsWork
        /// It failed since the catalogue was last read.
        case failedSinceTheLastRead
    }

    /// Why a plugin waits.
    public enum Wait: Equatable, Sendable {
        /// One of its card actions is running.
        case actionRunning
        /// Another install, update or removal is.
        case busy
    }

    /// What uDeck knows of one installed plugin when it asks.
    public struct Plugin: Equatable, Sendable {
        public var record: InstalledRecord
        /// What the head has for it, or nil when there is no catalogue.
        public var offer: UpdateOffer?
        /// Where its folder stands, as last hashed — nil when it has not been.
        public var standing: PluginStanding?
        /// What the manifest on disk asks for, or nil when it cannot be read.
        public var asksNow: [Capability]?
        /// What the head's manifest asks for, or nil when it cannot be read.
        public var asksAtHead: [Capability]?
        /// What replacing the folder would do to what is there now, by the
        /// rule every button that replaces a folder warns by.
        public var place: ShownPlace.Place.Fate
        /// Whether one of its card actions is running.
        public var actionRunning: Bool
        /// Whether its update by itself failed since the catalogue was read.
        public var failedSinceTheLastRead: Bool

        public init(record: InstalledRecord, offer: UpdateOffer?, standing: PluginStanding?, asksNow: [Capability]?,
                    asksAtHead: [Capability]?, place: ShownPlace.Place.Fate, actionRunning: Bool = false,
                    failedSinceTheLastRead: Bool = false) {
            self.record = record
            self.offer = offer
            self.standing = standing
            self.asksNow = asksNow
            self.asksAtHead = asksAtHead
            self.place = place
            self.actionRunning = actionRunning
            self.failedSinceTheLastRead = failedSinceTheLastRead
        }
    }

    /// What `plugin` comes to: `switchedOn` is **Update verified plugins by
    /// themselves** and **Official catalogue** together, `busy` whether another
    /// install, update or removal is running.
    public static func verdict(_ plugin: Plugin, switchedOn: Bool, busy: Bool) -> Verdict {
        guard switchedOn else { return .not(.switchedOff) }
        guard let offer = plugin.offer, offer.isWaiting, let version = offer.waitingVersion else {
            return .not(.nothingWaiting)
        }
        guard plugin.standing == .verified else { return .not(.notVerified) }
        guard !plugin.record.pinned else { return .not(.pinned) }
        guard let now = plugin.asksNow, let head = plugin.asksAtHead, !asksDifferently(now, head) else {
            return .not(.asksDifferently)
        }
        // `.deleted` is the one answer that means uDeck's own copy and nothing
        // else: no link, nothing the hash does not see, the tree as installed.
        guard plugin.place == .deleted else { return .not(.operatorsWork) }
        guard !plugin.failedSinceTheLastRead else { return .not(.failedSinceTheLastRead) }
        if plugin.actionRunning { return .later(.actionRunning) }
        if busy { return .later(.busy) }
        return .update(version: version)
    }

    /// Whether copies of `source` — `official`, or a source of one's own by
    /// its id — update themselves now, each copy deciding the rest itself
    /// (`verdict`): **Update verified plugins by themselves** on, and the
    /// source readable — the official one's under **Official catalogue**
    /// (`AppSettings.verifiedPluginsUpdateThemselves`), and not while its
    /// address answers another repository's number
    /// (`CatalogueError.officialRepositoryChanged`, `officialChanged`); a
    /// source of one's own's while it is among `sources`, the sources listed
    /// in a `sources.json` that can be read, whatever **Official catalogue**
    /// says (S4-04).
    public static func switchedOn(_ source: String, settings: AppSettings, sources: [OwnSource],
                                  officialChanged: Bool) -> Bool {
        guard source != InstalledPlugins.officialSource else {
            return settings.verifiedPluginsUpdateThemselves && !officialChanged
        }
        return settings.updatesVerifiedByThemselves && sources.contains { $0.id == source }
    }

    /// Whether two manifests ask for different things: as sets, each
    /// capability compared byte for byte, as **Allow** compares what was shown
    /// with what is asked (`ShownPlace.allows`). The order they are listed in,
    /// and a capability listed twice, change nothing.
    public static func asksDifferently(_ one: [Capability], _ other: [Capability]) -> Bool {
        !(one.allSatisfy { capability in other.contains { ShownPlace.same($0, capability) } }
            && other.allSatisfy { capability in one.contains { ShownPlace.same($0, capability) } })
    }

    /// What the installer throws when an update by itself comes to the swap
    /// and the plugin's place is no longer uDeck's own copy alone: something
    /// of the operator's came while it downloaded — a `.env`, an edit, a link
    /// — or the folder went. Replacing that warns first (`OperatorsWork`),
    /// and nobody is there to be warned, so the folder is left exactly as it
    /// was and the update waits on its row for a press. Not a failure.
    public struct OperatorsWorkCame: Error, Equatable, Sendable {
        public var id: String

        public init(id: String) {
            self.id = id
        }
    }
}

/// When uDeck asks `AutoUpdate` about the installed plugins, and what it keeps
/// between one asking and the next — decided here, where it is tested; the
/// model only says what happened.
///
/// * Only a read of the catalogue that succeeded makes the plugins due: one
///   that failed, or was left for later, changes nothing.
/// * They are asked on where their folders stand as hashed *after* that read
///   (`hashed`), never on standings from before it.
/// * A read forgets every failure since the read before it: a failed update by
///   itself is tried again once per read, and said on its row until then — or
///   until the next install, update or removal of that plugin, pressed or not.
/// * Once asked, they stay due while one of them waits — a card action, another
///   operation — or while an update by itself has just started, and the
///   minute's tick asks again; when none waits, not before the next read.
/// * An update by itself that was left as it was — a card action that started
///   while it downloaded, the switch turned off meanwhile, the operator's work
///   come to its place (`AutoUpdate.OperatorsWorkCame`) — is no failure: the
///   next asking says what becomes of it.
public struct AutoUpdateSchedule: Equatable, Sendable {
    /// How an update by itself that did not put its copy in place ended.
    public enum Ending: Equatable, Sendable {
        /// It failed: said on its row, and tried again after the next read.
        case failed
        /// The folder was left as it was, for a reason that is no failure.
        case leftAsItWas
    }

    /// Whether the installed plugins are still to be asked.
    public private(set) var due = false
    /// The plugins whose update by itself failed since the last read, and
    /// the version it was to: said on their rows.
    public private(set) var failures: [String: String] = [:]
    /// The hashing of the folders started after the last read, and the last
    /// one whose standings were applied: they count up.
    private var hashingAfterTheRead = 0
    private var hashingApplied = 0

    public init() {}

    /// A read of the catalogue ended — `succeeded` or not — and the hashing of
    /// the folders started after it is `hashing`.
    public mutating func read(succeeded: Bool, hashing: Int) {
        guard succeeded else { return }
        failures = [:]
        due = true
        hashingAfterTheRead = hashing
    }

    /// The standings the hashing numbered `hashing` came to were applied.
    public mutating func hashed(_ hashing: Int) {
        hashingApplied = max(hashingApplied, hashing)
    }

    /// Whether the plugins are asked now.
    public var asks: Bool {
        due && hashingApplied >= hashingAfterTheRead
    }

    /// The plugins were asked: `started` whether an update by itself began,
    /// `waits` whether one of them waits.
    public mutating func asked(started: Bool, waits: Bool) {
        due = started || waits
    }

    /// An install, update or removal of `id` began, pressed or not: what its
    /// row said of an update by itself that failed goes.
    public mutating func began(_ id: String) {
        failures[id] = nil
    }

    /// An update by itself of `id`, to `version`, threw `error`, and what
    /// that comes to: a card action still running when the plugin was quieted
    /// for it (`InstallError.stillRunning`) or the operator's work come to its
    /// place leaves the folder as it was; anything else is a failure.
    @discardableResult
    public mutating func ended(_ id: String, version: String, throwing error: any Error) -> Ending {
        switch error {
        case InstallError.stillRunning, is AutoUpdate.OperatorsWorkCame:
            return .leftAsItWas
        default:
            failures[id] = version
            return .failed
        }
    }
}

/// One `AutoUpdateSchedule` per source, by its id — the official source's and
/// each source of one's own's (stage 4): a read of one source makes only that
/// source's plugins due, and forgets only the failures of its own plugins, so
/// that one source's read never wipes another source's failure rows. The pass
/// asks each source's in turn (`asking(in:)`).
public struct AutoUpdateSchedules: Equatable, Sendable {
    public private(set) var schedules: [String: AutoUpdateSchedule] = [:]

    public init() {}

    /// The schedule of `source` — a fresh one for a source not read yet.
    public subscript(source: String) -> AutoUpdateSchedule {
        schedules[source] ?? AutoUpdateSchedule()
    }

    /// A read of `source` ended, `succeeded` or not, the hashing of the
    /// folders started after it being `hashing`.
    public mutating func read(_ source: String, succeeded: Bool, hashing: Int) {
        schedules[source, default: AutoUpdateSchedule()].read(succeeded: succeeded, hashing: hashing)
    }

    /// The hashing numbered `hashing` was applied: one hashing covers every
    /// source's folders.
    public mutating func hashed(_ hashing: Int) {
        for source in schedules.keys { schedules[source]?.hashed(hashing) }
    }

    /// The sources whose plugins are asked now, in `order` — the official
    /// source first, then the sources of one's own as `sources.json` lists
    /// them.
    public func asking(in order: [String]) -> [String] {
        order.filter { schedules[$0]?.asks == true }
    }

    /// `source`'s plugins were asked (`AutoUpdateSchedule.asked`).
    public mutating func asked(_ source: String, started: Bool, waits: Bool) {
        schedules[source]?.asked(started: started, waits: waits)
    }

    /// An install, update or removal of `id` began: what its row said of an
    /// update by itself that failed goes, whichever source's it was — one
    /// copy per id, and the copy may come from another source now.
    public mutating func began(_ id: String) {
        for source in schedules.keys { schedules[source]?.began(id) }
    }

    /// An update by itself of `id`, of `source`, to `version`, threw `error`
    /// (`AutoUpdateSchedule.ended`).
    @discardableResult
    public mutating func ended(_ source: String, id: String, version: String, throwing error: any Error) -> AutoUpdateSchedule.Ending {
        schedules[source, default: AutoUpdateSchedule()].ended(id, version: version, throwing: error)
    }

    /// Every plugin whose update by itself failed since its source was last
    /// read, and the version it was to: said on their rows.
    public var failures: [String: String] {
        schedules.values.reduce(into: [:]) { all, schedule in all.merge(schedule.failures) { first, _ in first } }
    }

    /// A source that was removed: nothing of it is asked or said any more.
    public mutating func forget(_ source: String) {
        schedules[source] = nil
    }
}

extension UpdateOffer {
    /// The version an update would bring, for the two offers that wait.
    public var waitingVersion: String? {
        switch self {
        case .newer(let version), .changedStill(let version): version
        default: nil
        }
    }
}

/// The permission decision across a swap of one verified copy for another.
///
/// A decision is held to the `version` it was made for (`PermissionGate`), so
/// that a new version asking for more asks again. A verified plugin that
/// updates itself every day would then stop every day until somebody agreed
/// again to exactly what they had agreed to. So when the copy on disk was
/// **Verified**, the copy that takes its place is too, and the new version
/// asks for exactly what the old one asked for, byte for byte, the decision —
/// whatever it was — is carried to the new version, unchanged otherwise. The
/// same for every such swap, pressed or not: **Update**, **Switch to**, **Back
/// to** and an earlier version. Anything else, and the decision is left as it
/// was: the card asks.
///
/// Carrying never grants anything: what the decision holds is what it held,
/// and the gate still holds every capability the new manifest asks for against
/// it.
public enum GrantCarry {
    /// One copy of a plugin, as far as the decision goes.
    public struct Copy: Equatable, Sendable {
        public var version: String
        public var asks: [Capability]
        /// Whether it stands **Verified**.
        public var verified: Bool

        public init(version: String, asks: [Capability], verified: Bool) {
            self.version = version
            self.asks = asks
            self.verified = verified
        }
    }

    /// The decision to keep after `old` — read before the swap; nil when it
    /// could not be read — was replaced by `new`.
    public static func after(_ grant: PluginGrant?, old: Copy?, new: Copy) -> PluginGrant? {
        guard let grant, let old, old.verified, new.verified,
              grant.decidedForVersion == old.version,
              !AutoUpdate.asksDifferently(old.asks, new.asks) else { return grant }
        return PluginGrant(granted: grant.granted, denied: grant.denied, decidedForVersion: new.version,
                           decidedAt: grant.decidedAt)
    }
}
