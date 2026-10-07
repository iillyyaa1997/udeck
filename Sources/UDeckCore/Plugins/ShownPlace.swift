import Foundation

/// What a warning before a button that takes a plugin's place said — carried
/// by the button that acts on it, and compared, when that button is pressed,
/// with what is there then.
///
/// A warning stays up as long as the operator reads it, and the disk does not
/// wait: a manifest's id is edited, a link is put where a folder was, the
/// catalogue moves on. A button that acted on what it found when pressed,
/// rather than on what its warning said, would act on something nobody was
/// told about — **Link a folder…** shown over `uptime`, its manifest's id
/// changed to `cpu` before **Link** was pressed, put the link in `cpu`'s place
/// and sent `cpu`'s copy to the Trash without a word (C2b's review). So the
/// press goes ahead only when what is there now is what the warning said,
/// byte for byte; otherwise it is the first press again — the warning of what
/// is there now, or, when nothing there needs one, the button's work at once,
/// as an unwarned press does it.
public enum ShownPlace {
    // MARK: - Link a folder…

    /// **Link a folder…** over an id that is taken, as its warning says it.
    public struct Linking: Equatable, Sendable {
        /// The id the link is named after: the folder's manifest's.
        public var id: String
        /// The folder the link leads to, every link on the way resolved.
        public var target: String
        /// What is at `plugins/<id>`.
        public var occupant: PluginLink.Occupant
        /// Whether what is there goes to the Trash (`OperatorsWork`).
        public var toTrash: Bool

        public init(id: String, target: String, occupant: PluginLink.Occupant, toTrash: Bool) {
            self.id = id
            self.target = target
            self.occupant = occupant
            self.toTrash = toTrash
        }

        /// What **Link a folder…** of `folder` finds now: the folder read as
        /// a plugin's (`PluginLink.candidate`), what is at its id, and whether
        /// that goes to the Trash by the installer's rule — `installed`
        /// being the records as uDeck holds them. Throws what
        /// `PluginLink.candidate` and `PluginLink.occupant` throw.
        public static func now(_ folder: URL, in paths: UDeckPaths,
                               installed: InstalledPlugins) throws -> (candidate: PluginLink.Candidate, shown: Linking) {
            let candidate = try PluginLink.candidate(folder, home: paths.root)
            let occupant = try PluginLink.occupant(for: candidate, in: paths)
            let id = candidate.id.rawValue
            let toTrash = OperatorsWork.goesToTrash(id, in: paths, record: installed.plugins[id])
            return (candidate, Linking(id: id, target: candidate.target, occupant: occupant, toTrash: toTrash))
        }
    }

    /// What **Link a folder…** does now.
    public enum LinkingStep: Equatable, Sendable {
        /// The id is free: the link is made at once.
        case linkAtOnce
        /// The id is a link to this folder already.
        case alreadyLinked
        /// The warning, of what is there now: nothing is done until it is
        /// confirmed.
        case ask(Linking)
        /// What the warning said is what is there: the link takes its place.
        case replace
    }

    /// What **Link a folder…** does, given the warning the operator confirmed
    /// (`confirmed`, nil for the first press) and what is there `now`.
    public static func linking(confirmed: Linking?, now: Linking) -> LinkingStep {
        switch now.occupant {
        case .nothing:
            return .linkAtOnce
        case .link(_, sameFolder: true):
            return .alreadyLinked
        case .link, .installed, .folderOfYourOwn:
            guard let confirmed, holds(confirmed, now: now) else { return .ask(now) }
            return .replace
        }
    }

    /// Whether the warning `shown` says what is there `now`: the same id, the
    /// same folder, the same thing at the id — a link to the same place, a
    /// plugin from the same source — and the same answer about the Trash.
    /// Every text by its bytes: two spellings of one name are two folders
    /// where the disk keeps them apart.
    public static func holds(_ shown: Linking, now: Linking) -> Bool {
        same(shown.id, now.id) && same(shown.target, now.target)
            && same(shown.occupant, now.occupant) && shown.toTrash == now.toTrash
    }

    // MARK: - Remove, Install, Replace…, Update, Reinstall, Back to

    /// What a button puts at `plugins/<id>` — and so the version and the copy
    /// its warning names. Which copy is the button's to say, and two buttons
    /// that put the same version there take it from different places: a
    /// warning that named the version alone, or the wrong copy, would hold its
    /// button to nothing the repository could not change under it (C2b2's
    /// review: **Update** installed a tree published under the version its
    /// warning had named, and nobody had been shown it).
    public enum Arrival: Equatable, Sendable {
        /// **Remove**: nothing comes.
        case nothing
        /// **Install**, **Replace…**, **Update** and **Switch to**: `version`
        /// from the catalogue's head. The copy is the plugin folder's `tree`
        /// there: the head moves on with every merge, the folder only when it
        /// changed.
        case atHead(version: String, tree: String)
        /// **Reinstall**, **Back to** and an earlier version: `version` at
        /// `commit`, the commit the files are taken from — and so the copy.
        case atCommit(version: String, commit: String)

        /// The version that comes; nil for **Remove**.
        public var version: String? {
            switch self {
            case .nothing: nil
            case .atHead(let version, _), .atCommit(let version, _): version
            }
        }

        /// The copy that comes, as the warning names it (`Place.copy`); nil
        /// for **Remove**.
        public var copy: String? {
            switch self {
            case .nothing: nil
            case .atHead(_, let tree): tree
            case .atCommit(_, let commit): commit
            }
        }
    }

    /// What a button that takes an installed plugin's place does to what is
    /// at `plugins/<id>` — and the version and copy that come in its place —
    /// as its warning says it.
    public struct Place: Equatable, Sendable {
        /// What becomes of what is at `plugins/<id>`, by the installer's own
        /// rule (`OperatorsWork`, `PluginInstaller.isLink`).
        public enum Fate: Equatable, Sendable {
            /// Nothing is there.
            case nothing
            /// A link is there, to `leadsTo` — the folder, or what the link
            /// says when it leads nowhere: only the link goes.
            case linkGoes(leadsTo: String)
            /// A folder holding something of the operator's: to the Trash.
            case toTrash
            /// A folder that is exactly what uDeck put there: deleted.
            case deleted
        }

        public var fate: Fate
        /// The version that comes in its place; nil for **Remove**.
        public var arriving: String?
        /// Which copy of that version comes, by the name git gives its
        /// files: the plugin folder's tree at the catalogue's head for
        /// **Install** and **Update** — the head moves on with every merge,
        /// the folder only when it changed — and the commit the files are
        /// taken from for a button that installs at a commit. Nil for
        /// **Remove**. A version is only what a manifest says: the repository
        /// can publish another tree under the one the warning named.
        public var copy: String?

        public init(fate: Fate, arriving: String?, copy: String? = nil) {
            self.fate = fate
            self.arriving = arriving
            self.copy = copy
        }

        /// Where the link leads, when a link is what is there.
        public var link: String? {
            if case .linkGoes(let leadsTo) = fate { leadsTo } else { nil }
        }

        /// What a button that takes `plugins/<id>` would do now, with
        /// `record` the plugin's record as uDeck holds it, and `arrival` what
        /// the button would put there. The one way a button asks: what it
        /// puts there says the version and the copy together.
        public static func now(_ id: String, in paths: UDeckPaths, record: InstalledRecord?,
                               bringing arrival: Arrival) -> Place {
            now(id, in: paths, record: record, arriving: arrival.version, copy: arrival.copy)
        }

        /// As `now(_:in:record:bringing:)`, given the version and the copy
        /// apart — for the tests of what is there; a button says its
        /// `Arrival`.
        static func now(_ id: String, in paths: UDeckPaths, record: InstalledRecord?, arriving: String?,
                        copy: String? = nil) -> Place {
            let live = paths.plugins.appendingPathComponent(id, isDirectory: true)
            guard PluginInstaller.folderIsTaken(id, in: paths) else {
                return Place(fate: .nothing, arriving: arriving, copy: copy)
            }
            if PluginInstaller.isLink(live) {
                let leadsTo = FilePaths.real(live.path).path
                    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: live.path)) ?? live.path
                return Place(fate: .linkGoes(leadsTo: leadsTo), arriving: arriving, copy: copy)
            }
            return Place(fate: OperatorsWork.goesToTrash(id, in: paths, record: record) ? .toTrash : .deleted,
                         arriving: arriving, copy: copy)
        }
    }

    /// Which button: what it warns of decides when it asks first.
    public enum Button: Equatable, Sendable {
        /// **Remove**: it always asks first.
        case remove
        /// **Install**, and **Replace…** on a catalogue row: first over a link
        /// or over a folder holding something of the operator's.
        case install
        /// **Update**, **Switch to**, **Reinstall**, **Back to** and an
        /// earlier version: first over a copy holding something of the
        /// operator's, or over a link — one put where the copy was while
        /// the warning was up included: the link goes, not the copy.
        case replaceCopy
    }

    /// What a press comes to.
    public enum Press: Equatable, Sendable {
        /// The button does its work.
        case goAhead
        /// The warning, of what is there now; nothing is done.
        case ask(Place)
    }

    /// Whether `button` warns first of `now`.
    public static func warns(_ button: Button, of now: Place) -> Bool {
        switch button {
        case .remove: true
        case .install, .replaceCopy: now.fate == .toTrash || now.link != nil
        }
    }

    /// What a press of `button` comes to, given the warning the operator
    /// confirmed (`shown`, nil for a press nothing was shown before) and
    /// what is there `now`: ahead when the warning said what is there now;
    /// otherwise as a first press — the warning of what is there now, or the
    /// button's work at once when nothing there is warned of.
    public static func press(_ button: Button, shown: Place?, now: Place) -> Press {
        if let shown, holds(shown, now: now) { return .goAhead }
        return warns(button, of: now) ? .ask(now) : .goAhead
    }

    /// Whether the warning `shown` says what is there `now`, and names the
    /// copy that comes now, byte for byte.
    public static func holds(_ shown: Place, now: Place) -> Bool {
        guard same(shown.arriving, now.arriving), same(shown.copy, now.copy) else { return false }
        switch (shown.fate, now.fate) {
        case (.nothing, .nothing), (.toTrash, .toTrash), (.deleted, .deleted): return true
        case (.linkGoes(let one), .linkGoes(let other)): return same(one, other)
        default: return false
        }
    }

    // MARK: - What each button comes to

    /// What a press of a button that takes a plugin's place comes to — decided
    /// here, whole: which copy the button brings, from which commit, what is
    /// there now and whether its warning holds. Settings' buttons pass what
    /// they have (the catalogue, the records, the warning confirmed) and do
    /// what this says; none of them chooses a copy of its own. A choice made
    /// where no test reaches it was the bug twice (C2b2's review: **Update**
    /// asking with no copy; D1b's: the same, one call further in).
    public enum Step: Equatable, Sendable {
        /// Nothing to do: the catalogue does not have the plugin, or there is
        /// no copy to go back to.
        case nothing
        /// The warning, of what is there now; nothing is done.
        case ask(Place)
        /// `operation` of the plugin's folder as the catalogue lists it at
        /// `commit`: **Install**, **Replace…**, **Update**, **Switch to**.
        case install(InstallRequest.Operation, commit: String, folder: PluginListing, version: String)
        /// `operation` at `commit`, whose listing is read first:
        /// **Reinstall**, **Back to** and an earlier version.
        case atCommit(InstallRequest.Operation, commit: String, version: String)
        /// **Remove**.
        case remove
    }

    /// **Install** — or **Replace…** over a folder of the operator's own or a
    /// link — at the commit the catalogue was built from: the folder's tree
    /// there is the copy its warning names. An update when uDeck installed it
    /// before, a replace when something of the operator's is in its place.
    public static func install(_ id: String, catalogue: Catalogue?, in paths: UDeckPaths, installed: InstalledPlugins,
                               shown: Place?) -> Step {
        guard let catalogue, let entry = catalogue.entry(id) else { return .nothing }
        let version = entry.manifest?.version ?? ""
        let now = Place.now(id, in: paths, record: installed.plugins[id],
                            bringing: .atHead(version: version, tree: entry.listing.tree))
        if case .ask(let place) = press(.install, shown: shown, now: now) { return .ask(place) }
        let operation: InstallRequest.Operation = installed.plugins[id] != nil
            ? .update : (PluginInstaller.folderIsTaken(id, in: paths) ? .replace : .install)
        return .install(operation, commit: catalogue.commit, folder: entry.listing, version: version)
    }

    /// **Update**, or **Switch to** a version the repository went back to:
    /// the plugin at the catalogue's head — the folder's tree there, which a
    /// republish of the same version changes, is the copy its warning names.
    public static func update(_ id: String, catalogue: Catalogue?, in paths: UDeckPaths, installed: InstalledPlugins,
                              shown: Place?) -> Step {
        guard let catalogue, let entry = catalogue.entry(id) else { return .nothing }
        let version = entry.manifest?.version ?? ""
        let now = Place.now(id, in: paths, record: installed.plugins[id],
                            bringing: .atHead(version: version, tree: entry.listing.tree))
        if case .ask(let place) = press(.replaceCopy, shown: shown, now: now) { return .ask(place) }
        return .install(.update, commit: catalogue.commit, folder: entry.listing, version: version)
    }

    /// **Reinstall**: what the record says was installed, put back — the
    /// record's commit is the copy.
    public static func reinstall(_ id: String, in paths: UDeckPaths, installed: InstalledPlugins, shown: Place?) -> Step {
        guard let record = installed.plugins[id] else { return .nothing }
        return atCommit(.reinstall, id: id, commit: record.commit, version: record.version, in: paths, installed: installed,
                        shown: shown)
    }

    /// **Back to** the copy this one replaced.
    public static func backToPrevious(_ id: String, in paths: UDeckPaths, installed: InstalledPlugins, shown: Place?) -> Step {
        guard let previous = installed.plugins[id]?.previous else { return .nothing }
        return atCommit(.earlier, id: id, commit: previous.commit, version: previous.version, in: paths, installed: installed,
                        shown: shown)
    }

    /// An earlier version, chosen from the folder's history.
    public static func earlier(_ id: String, line: PluginHistory.Line, in paths: UDeckPaths, installed: InstalledPlugins,
                               shown: Place?) -> Step {
        atCommit(.earlier, id: id, commit: line.commit, version: line.version, in: paths, installed: installed, shown: shown)
    }

    /// A copy replaced by `version` at `commit`: the commit its warning names
    /// is the one the files come from.
    static func atCommit(_ operation: InstallRequest.Operation, id: String, commit: String, version: String,
                         in paths: UDeckPaths, installed: InstalledPlugins, shown: Place?) -> Step {
        let now = Place.now(id, in: paths, record: installed.plugins[id], bringing: .atCommit(version: version, commit: commit))
        if case .ask(let place) = press(.replaceCopy, shown: shown, now: now) { return .ask(place) }
        return .atCommit(operation, commit: commit, version: version)
    }

    /// **Remove**: nothing comes, and it always asks first.
    public static func remove(_ id: String, in paths: UDeckPaths, installed: InstalledPlugins, shown: Place?) -> Step {
        let now = Place.now(id, in: paths, record: installed.plugins[id], bringing: .nothing)
        if case .ask(let place) = press(.remove, shown: shown, now: now) { return .ask(place) }
        return .remove
    }

    // MARK: - Allow

    /// Whether **Allow** grants nothing the operator was not shown: every
    /// capability the manifest asks for now is either held already — granted
    /// for this version — or among those the card or Settings listed
    /// (`shown`), byte for byte. The grant covers what the manifest asks when
    /// the button is pressed; a manifest edited while the card was up — a
    /// linked working copy's, say — asking for one command more is asked about
    /// again rather than granted unseen. **Decline** needs no such test:
    /// refusing what was not shown only keeps the plugin from running.
    public static func allows(shown: [Capability], requested: [Capability], grant: PluginGrant?, version: String) -> Bool {
        let held = grant.flatMap { $0.decidedForVersion == version ? $0.granted : nil } ?? []
        return requested.allSatisfy { capability in
            held.contains(capability) || shown.contains { same($0, capability) }
        }
    }

    // MARK: - By bytes

    static func same(_ one: Capability, _ other: Capability) -> Bool {
        switch (one, other) {
        case (.read(let first), .read(let second)), (.write(let first), .write(let second)),
             (.exec(let first), .exec(let second)), (.network(let first), .network(let second)),
             (.secret(let first), .secret(let second)):
            same(first, second)
        case (.screen, .screen):
            true
        default:
            false
        }
    }

    static func same(_ one: String, _ other: String) -> Bool {
        one.utf8.elementsEqual(other.utf8)
    }

    static func same(_ one: String?, _ other: String?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case (let one?, let other?): same(one, other)
        default: false
        }
    }

    static func same(_ one: PluginLink.Occupant, _ other: PluginLink.Occupant) -> Bool {
        switch (one, other) {
        case (.nothing, .nothing), (.folderOfYourOwn, .folderOfYourOwn):
            true
        case (.link(let first, let firstSame), .link(let second, let secondSame)):
            same(first, second) && firstSame == secondSame
        case (.installed(let first), .installed(let second)):
            same(first, second)
        default:
            false
        }
    }
}
