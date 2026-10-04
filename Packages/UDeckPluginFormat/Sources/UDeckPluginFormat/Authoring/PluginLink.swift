#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A plugin folder an author works on, put into uDeck as a link:
/// `<home>/plugins/<id>` → the folder. `udeck-plugin link`, and uDeck's own
/// **Link a folder…** (`DeckModel.linkFolder`).
///
/// A link, and nothing else. The folder stays where it is — in a working copy
/// of a repository, usually — and stays exactly as it is; uDeck's
/// `installed.json` is not touched, since the link is no install: no source,
/// no commit, nothing to verify. `udeck-plugin link` links only a free id:
/// one id is one copy on a machine, so a link from the command never takes
/// the place of a plugin uDeck installed nor of a folder somebody put there.
/// uDeck itself can put one in an installed plugin's place, after saying so
/// (`PluginInstaller.link`).
public enum PluginLink {
    /// Whether this uDeck lists a plugin whose folder in `plugins/` is a link:
    /// it does — discovery follows the link (`PluginDiscovery.scan`) and the
    /// folder watcher watches where it leads.
    public static let udeckReadsLinks = true

    public struct Linked: Sendable {
        /// `<home>/plugins/<id>`.
        public var link: URL
        /// Where it points: the folder, as an absolute path with every link
        /// on the way resolved.
        public var target: String
        /// It was there already, pointing at the same folder.
        public var wasThere: Bool
    }

    /// Why nothing was linked. `isUsage` when the folder is not one to link
    /// — no manifest, nothing uDeck could read — rather than the id being
    /// taken.
    public struct Refusal: Error, CustomStringConvertible {
        public var description: String
        public var isUsage: Bool
    }

    /// A folder that can be linked: the id its manifest gives, which the link
    /// is named after, and the folder itself, every link on the way resolved.
    public struct Candidate: Equatable, Sendable {
        public var id: PluginIdentifier
        public var target: String
    }

    /// What is at `<home>/plugins/<id>` now, as a link would find it.
    public enum Occupant: Equatable, Sendable {
        /// Nothing: the id is free.
        case nothing
        /// A link already, to `destination` as it is written; `sameFolder`
        /// when it leads to the folder being linked.
        case link(destination: String, sameFolder: Bool)
        /// A plugin uDeck installed from a repository — its record in
        /// `installed.json`, whether or not its folder is there.
        case installed(source: String)
        /// A folder, or anything else, that uDeck did not install.
        case folderOfYourOwn
    }

    /// Reads `folder` as a folder to link into the uDeck folder `home`.
    public static func candidate(_ folder: URL, home: URL) throws -> Candidate {
        guard let target = realPath(folder.path) else {
            throw Refusal(description: "\(folder.path) is not there", isUsage: true)
        }
        guard (try? FileManager.default.attributesOfItem(atPath: target))?[.type] as? FileAttributeType == .typeDirectory else {
            throw Refusal(description: "\(folder.path) is not a folder", isUsage: true)
        }
        // What discovery would not follow, refused before anything is made:
        // uDeck writes and deletes in its own folder, and a plugin's folder
        // must be none of that (`LinkRefusal`).
        if let udeck = realPath(home.path) {
            if FilePaths.contains(udeck, target) {
                throw Refusal(description: "\(folder.path) is inside uDeck's own folder \(udeck), where uDeck writes and "
                              + "deletes; link a folder of your own", isUsage: true)
            }
            if FilePaths.contains(target, udeck) {
                throw Refusal(description: "\(folder.path) holds uDeck's own folder \(udeck); link the plugin folder "
                              + "itself", isUsage: true)
            }
        }
        let manifestURL = URL(fileURLWithPath: target).appendingPathComponent(PluginDiscovery.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw Refusal(description: "\(folder.path) has no \(PluginDiscovery.manifestFilename) to read, so it is not "
                          + "a plugin folder", isUsage: true)
        }
        do {
            return Candidate(id: try JSONDecoder().decode(PluginManifest.self, from: data).id, target: target)
        } catch {
            throw Refusal(description: "\(manifestURL.path) is not a manifest uDeck can read: "
                          + PluginDiscovery.describe(error, in: data, document: "the manifest")
                          + "; the link is named after its id", isUsage: true)
        }
    }

    /// What is at `<home>/plugins/<id>` for `candidate`. Throws when
    /// `installed.json` cannot be read: whether the id is installed is then
    /// not known.
    public static func occupant(for candidate: Candidate, in paths: UDeckPaths) throws -> Occupant {
        if let source = try installedSource(of: candidate.id, in: paths) { return .installed(source: source) }
        let link = paths.plugins.appendingPathComponent(candidate.id.rawValue)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) else { return .nothing }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .folderOfYourOwn }
        let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? "somewhere else"
        let same = realPath(link.path).map { samePath($0, candidate.target) } ?? false
        return .link(destination: destination, sameFolder: same)
    }

    /// Makes the link `<home>/plugins/<id>` → the candidate's folder, where
    /// nothing is: failing, rather than replacing, whatever appeared there.
    @discardableResult
    public static func place(_ candidate: Candidate, in paths: UDeckPaths) throws -> URL {
        let link = paths.plugins.appendingPathComponent(candidate.id.rawValue)
        do {
            try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: candidate.target)
        } catch {
            throw Refusal(description: "could not link \(link.path): \(error)", isUsage: false)
        }
        return link
    }

    /// Links `folder` into the uDeck folder `home`: `udeck-plugin link`, for
    /// a free id only.
    public static func link(_ folder: URL, home: URL) throws -> Linked {
        let candidate = try candidate(folder, home: home)
        let id = candidate.id
        let target = candidate.target
        let paths = UDeckPaths(root: home)
        let link = paths.plugins.appendingPathComponent(id.rawValue)
        switch try occupant(for: candidate, in: paths) {
        case .nothing:
            break
        case .installed(let source):
            // What this release of uDeck has for it: Remove, beside the plugin
            // in Settings. Putting a link in an installed plugin's place is
            // uDeck's own to do, where it can say what goes to the Trash.
            throw Refusal(description: "\(id.rawValue) is installed in uDeck from \(source); a link never takes the place "
                          + "of a plugin uDeck installed. To work on it from \(target) instead, remove the installed copy "
                          + "first -- Remove, beside it under Plugins in uDeck's Settings -- and link again",
                          isUsage: false)
        case .link(_, sameFolder: true):
            return Linked(link: link, target: target, wasThere: true)
        case .link(let destination, sameFolder: false):
            throw Refusal(description: "\(link.path) is already a link, to \(destination); take it away first "
                          + "(rm \(shellQuoted(link.path)) -- that takes the link, never what it points at)",
                          isUsage: false)
        case .folderOfYourOwn:
            throw Refusal(description: "\(link.path) is already there, a plugin folder uDeck did not install; move it "
                          + "out of the way first", isUsage: false)
        }
        try place(candidate, in: paths)
        return Linked(link: link, target: target, wasThere: false)
    }

    /// Where uDeck installed `id` from, when `installed.json` says it did.
    /// Read as JSON alone, for one question — whether the id is a key of
    /// `plugins` — which every version of the file answers the same way.
    static func installedSource(of id: PluginIdentifier, in paths: UDeckPaths) throws -> String? {
        let file = paths.installedFile
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let bytes = try? Data(contentsOf: file) else {
            throw Refusal(description: "could not read \(file.path), so whether \(id.rawValue) is installed is not "
                          + "known; nothing was linked", isUsage: false)
        }
        let document = StrictJSON.parse(Array(bytes))
        guard let installed = document.value?.object?.first("plugins")?.object else {
            throw Refusal(description: "\(file.path) is not the list of installed plugins uDeck writes"
                          + (document.problems.first.map { " (it \($0))" } ?? "")
                          + "; uDeck installs nothing while it is broken, and nothing was linked", isUsage: false)
        }
        guard let record = installed.first(id.rawValue) else { return nil }
        let repository = record.object?.first("repository")?.object
        if let host = repository?.first("host")?.string, let path = repository?.first("path")?.string {
            return "\(host)/\(path)"
        }
        return "a repository"
    }

    /// `path` as an absolute path with every link on the way resolved, or nil
    /// when there is nothing there.
    static func realPath(_ path: String) -> String? {
        FilePaths.real(path).path
    }

    /// Whether two resolved paths are one, byte for byte. Not `==`: Swift
    /// compares strings by what they mean, so `café` spelt with `é` and with
    /// `e` and a combining accent are one string — and on Linux they are two
    /// folders. A Mac's `realpath` answers the name a folder has on disk,
    /// however it was asked for, so the same folder resolves to the same bytes.
    public static func samePath(_ one: String, _ other: String) -> Bool {
        one.utf8.elementsEqual(other.utf8)
    }

    /// `path` as one word for a POSIX shell: as it is when nothing in it means
    /// anything to one, in single quotes otherwise — a quote inside written
    /// `'\''` — so that a command the author copies from what the command
    /// printed acts on that path and on nothing else.
    public static func shellQuoted(_ path: String) -> String {
        let plain = !path.isEmpty && path.utf8.allSatisfy { byte in
            ASCII.isLowercaseLetterOrDigit(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                || "/._-+,:@%=".utf8.contains(byte)
        }
        if plain { return path }
        var quoted = "'"
        for scalar in path.unicodeScalars {
            if scalar == "'" { quoted += "'\\''" } else { quoted.unicodeScalars.append(scalar) }
        }
        return quoted + "'"
    }
}
