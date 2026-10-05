import Foundation

/// **Where to look for commands** in Settings → Plugins: the folders a bare
/// command — `"run": ["python3", …]` — is looked up in, in order
/// (`AppSettings.pluginExecutableSearchPath`, `PluginDiscovery`), and what
/// each of the field's controls does to the list.
///
/// Every change is a new list, written to `settings.json` like every other
/// setting, and counts from the next run: a run reads the search path when it
/// starts (`PollLoops`), so nothing restarts.
///
/// Folders are compared as bytes, as everything that compares a path here: two
/// spellings of one name are two folders where the disk keeps them apart.
public enum SearchPathList {
    /// What uDeck says of one folder in the list.
    public enum Standing: Equatable, Sendable {
        /// Looked in.
        case lookedIn
        /// Written from `/`, and nothing is there now. Kept, and looked in:
        /// a folder a tool is installed into later, or a disk not mounted, is
        /// there again without anybody editing the list.
        case notThere
        /// Something is there, and it is not a folder: nothing is found in it.
        case notAFolder
        /// Not written from `/` — `bin`, `~/bin` — and never looked in
        /// (`PluginEnvironment.lookedIn`). Settings adds only full paths; such
        /// a folder was written into `settings.json` by hand.
        case notAFullPath
    }

    /// What `folder` is, asked of the disk now.
    public static func standing(of folder: String) -> Standing {
        guard FilePaths.isAbsolute(folder) else { return .notAFullPath }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) else { return .notThere }
        return isFolder.boolValue ? .lookedIn : .notAFolder
    }

    /// `folder` added, first — a folder added is added to be found before the
    /// system's own: a Python from pyenv over `/usr/bin`'s — unless it is in
    /// the list already, which is then as it was. Only a full path is added.
    public static func adding(_ folder: String, to list: [String]) -> [String] {
        guard FilePaths.isAbsolute(folder), !list.contains(where: { same($0, folder) }) else { return list }
        return [folder] + list
    }

    /// Whether the folder at `index` can go: not when it is the last folder
    /// looked in — an empty list, or one of folders never looked in, is a
    /// search path that finds nothing, and uDeck would put its default back
    /// in its place on the next read (`PluginEnvironment.effective`).
    public static func canRemove(at index: Int, from list: [String]) -> Bool {
        guard list.indices.contains(index) else { return false }
        var rest = list
        rest.remove(at: index)
        return !PluginEnvironment.lookedIn(rest).isEmpty
    }

    /// The list without the folder at `index`, when it can go; as it was
    /// otherwise.
    public static func removing(at index: Int, from list: [String]) -> [String] {
        guard canRemove(at: index, from: list) else { return list }
        var rest = list
        rest.remove(at: index)
        return rest
    }

    /// The list with the folder at `index` moved one place up (`by: -1`) or
    /// down (`by: 1`); as it was at either end.
    public static func moving(at index: Int, by offset: Int, in list: [String]) -> [String] {
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target), abs(offset) == 1 else { return list }
        var moved = list
        moved.swapAt(index, target)
        return moved
    }

    /// **Restore the defaults**.
    public static var defaults: [String] { PluginEnvironment.defaultSearchPath }

    /// `folder` as the list shows it: the home folder as `~`, the way the
    /// operator writes it — only for display; the list keeps the full path.
    public static func shown(_ folder: String, home: String) -> String {
        let folderBytes = Array(folder.utf8)
        let homeBytes = Array(home.utf8)
        guard !homeBytes.isEmpty, homeBytes != [UInt8(ascii: "/")] else { return folder }
        if folderBytes == homeBytes { return "~" }
        guard FilePaths.isInside(home, folder) else { return folder }
        let rest = folderBytes.dropFirst(homeBytes.count + (homeBytes.last == UInt8(ascii: "/") ? 0 : 1))
        return "~/" + String(decoding: rest, as: UTF8.self)
    }

    private static func same(_ one: String, _ other: String) -> Bool {
        one.utf8.elementsEqual(other.utf8)
    }
}
