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
        /// `record` the plugin's record as uDeck holds it, and `arriving`
        /// and `copy` what the button would put there.
        public static func now(_ id: String, in paths: UDeckPaths, record: InstalledRecord?, arriving: String?,
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
