import Foundation

/// Where every plugin folder stands, from what each installed one hashes to
/// now — what uDeck finds each time the plugins folder is read, and after each
/// read of the catalogue. Never trusted from `installed.json`: nothing, least
/// of all a consent decision, is decided on what the file says.
///
/// In three steps, so that the one that takes time is never on the main
/// thread and the two that decide are tested: the folders to hash
/// (`folders(of:installed:)`), hashing them (`trees(of:hash:)`, away from the
/// main thread), and what that comes to (`of(_:installed:trees:head:now:)`).
public struct Reverification: Equatable, Sendable {
    /// Every plugin folder's standing, by its name in the plugins folder, and
    /// `missing` for a record whose folder is not there.
    public var standings: [String: PluginStanding]
    /// The records with what was found, when it changed what a record says —
    /// to be written to `installed.json`; nil when nothing is to be written.
    public var records: InstalledPlugins?

    public init(standings: [String: PluginStanding], records: InstalledPlugins?) {
        self.standings = standings
        self.records = records
    }

    /// The head of the catalogue's default branch, as far as it is known.
    public enum Head: Equatable, Sendable {
        /// The catalogue has not been read yet. uDeck reads its cache away from
        /// the main thread, a moment after the plugins folder is first read:
        /// until then a record's verification is not written again, or every
        /// launch would write the install's own commit over the head it was
        /// checked against, and the read after the catalogue write it back.
        case notReadYet
        /// Read: the commit of the default branch — nil when there is no
        /// catalogue, and then a record is checked against its own commit.
        case read(String?)
    }

    /// The folders whose trees decide something, by name: every plugin folder
    /// uDeck has a record of. Not a linked folder's: it is no install, and a
    /// record left from a copy a link took the place of by hand is neither
    /// read from its tree nor written — a linked plugin is never in
    /// `installed.json`, and its working copy is not hashed.
    public static func folders(of plugins: [DiscoveredPlugin], installed: InstalledPlugins) -> [String: URL] {
        var folders: [String: URL] = [:]
        for plugin in plugins where !plugin.isLinked && installed.plugins[plugin.folderName] != nil {
            folders[plugin.folderName] = plugin.directory
        }
        return folders
    }

    /// Each folder's tree, hashed as git would — nil for one that would not
    /// hash. `nonisolated` and `async`: it runs on the cooperative pool
    /// whoever awaits it, so the panel's actor never hashes a plugin's files.
    public static func trees(
        of folders: [String: URL],
        hash: @Sendable (URL) -> String? = { Reverification.tree($0) }
    ) async -> [String: String?] {
        var trees: [String: String?] = [:]
        for (id, folder) in folders { trees[id] = .some(hash(folder)) }
        return trees
    }

    /// `folder`'s tree, as git hashes it.
    public static func tree(_ folder: URL) -> String? {
        (try? GitHash.tree(ofDirectoryAt: folder)) ?? nil
    }

    /// What `plugins`, as the plugins folder was read, and the `trees` of the
    /// folders `folders(of:installed:)` named come to.
    public static func of(
        _ plugins: [DiscoveredPlugin],
        installed: InstalledPlugins,
        trees: [String: String?],
        head: Head,
        now: Date
    ) -> Reverification {
        var standings: [String: PluginStanding] = [:]
        var records = installed
        var changed = false
        for plugin in plugins {
            let id = plugin.folderName
            guard let record = installed.plugins[id], !plugin.isLinked else {
                standings[id] = .folderOfYourOwn
                continue
            }
            let tree = trees[id] ?? nil
            standings[id] = PluginStanding.of(record: record, folderExists: true, treeOnDisk: tree)
            guard case .read(let headCommit) = head else { continue }
            let found = record.verification(treeOnDisk: tree, headCommit: headCommit, now: now)
            if !found.saysTheSame(as: record.verification) {
                records.plugins[id]?.verification = found
                changed = true
            }
        }
        for id in installed.plugins.keys where standings[id] == nil { standings[id] = .missing }
        return Reverification(standings: standings, records: changed ? records : nil)
    }
}
