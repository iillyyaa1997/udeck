import Foundation

/// What the plugins folder's watcher watches beside the plugins folder: every
/// folder a linked plugin's link leads to.
///
/// A linked folder's files are somewhere else — an author's working copy —
/// and a change there is a change to the plugin: a manifest edited, a producer
/// made executable. The link itself, pointed elsewhere or taken away, is an
/// entry in the plugins folder, so the folder's own watch sees that; the next
/// read gives the list from here again.
///
/// A link that leads nowhere is not watched — there is nothing to watch — and
/// is read again with the plugins folder: on any change in it, or **Look
/// again**.
public enum WatchedFolders {
    /// The folders followed links lead to, each once, in the order read.
    public static func linked(_ plugins: [DiscoveredPlugin]) -> [URL] {
        var folders: [URL] = []
        var seen: Set<[UInt8]> = []
        for plugin in plugins where plugin.isLinked && plugin.directory != plugin.linkedAt {
            // By bytes, as everything that compares a path here: two
            // spellings of one name are two folders where the disk keeps them
            // apart, and both are watched.
            guard seen.insert(Array(plugin.directory.path.utf8)).inserted else { continue }
            folders.append(plugin.directory)
        }
        return folders
    }

    /// What the watcher holds as watched after asking for a stream of `paths`:
    /// those paths when the stream was made — or there was nothing to watch —
    /// and none when it was not. So a stream that could not be made is asked
    /// for again on the next read of the plugins folder, rather than that read
    /// finding the same list, taking it for watched, and the working copy's
    /// edits going unnoticed until the links changed.
    public static func remembered(_ paths: [String], streamMade: Bool) -> [String] {
        streamMade || paths.isEmpty ? paths : []
    }

    /// Whether a read of the plugins folder after `changes` hashes the plugins
    /// uDeck installed again (`Reverification`) — nil being a read nobody
    /// watched for: at launch, **Look again**, after an install.
    ///
    /// Only a change in the plugins folder itself can change an installed
    /// plugin's tree. A folder a link leads to is never inside uDeck's folder,
    /// nor around it (`LinkRefusal`), and a linked folder is never hashed: a
    /// working copy that is written into all the time — an editor, a build,
    /// `git` — reads the plugins folder again each time, and hashes nothing.
    public static func rehashes(after changes: Set<FolderChange>?) -> Bool {
        guard let changes else { return true }
        return changes.contains(.pluginsFolder)
    }
}

/// Where the watcher saw something change.
public enum FolderChange: Hashable, Sendable {
    /// In the plugins folder: a plugin folder, a link, a file in an installed
    /// plugin.
    case pluginsFolder
    /// In a folder a link leads to — an author's working copy.
    case linkedFolder
}
