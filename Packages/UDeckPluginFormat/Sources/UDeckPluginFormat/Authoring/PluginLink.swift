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
/// `<home>/plugins/<id>` → the folder. `udeck-plugin link`.
///
/// A link, and nothing else. The folder stays where it is — in a working copy
/// of a repository, usually — and stays exactly as it is; uDeck's
/// `installed.json` is not touched, since the link is no install: no source,
/// no commit, nothing to verify. Only a free id is linked: one id is one copy
/// on a machine, so a link never takes the place of a plugin uDeck installed
/// (that is for uDeck itself to do, in Settings, with the warning it gives)
/// nor of a folder somebody put there.
public enum PluginLink {
    /// Whether this uDeck lists a plugin whose folder in `plugins/` is a link.
    /// Not yet: its discovery skips a link (`PluginDiscovery.scan`) and its
    /// watcher does not follow one. When it does, this turns true and the
    /// command stops saying so.
    public static let udeckReadsLinks = false

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

    /// Links `folder` into the uDeck folder `home`.
    public static func link(_ folder: URL, home: URL) throws -> Linked {
        guard let target = realPath(folder.path) else {
            throw Refusal(description: "\(folder.path) is not there", isUsage: true)
        }
        guard (try? FileManager.default.attributesOfItem(atPath: target))?[.type] as? FileAttributeType == .typeDirectory else {
            throw Refusal(description: "\(folder.path) is not a folder", isUsage: true)
        }
        let manifestURL = URL(fileURLWithPath: target).appendingPathComponent(PluginDiscovery.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw Refusal(description: "\(folder.path) has no \(PluginDiscovery.manifestFilename) to read, so it is not "
                          + "a plugin folder", isUsage: true)
        }
        let id: PluginIdentifier
        do {
            id = try JSONDecoder().decode(PluginManifest.self, from: data).id
        } catch {
            throw Refusal(description: "\(manifestURL.path) is not a manifest uDeck can read: "
                          + PluginDiscovery.describe(error, in: data, document: "the manifest")
                          + "; the link is named after its id", isUsage: true)
        }

        let paths = UDeckPaths(root: home)
        if let source = try installedSource(of: id, in: paths) {
            throw Refusal(description: "\(id.rawValue) is installed in uDeck from \(source); a link never takes the place "
                          + "of a plugin uDeck installed. To work on it from \(target), replace the installed copy with "
                          + "Link a folder… in uDeck's Settings", isUsage: false)
        }

        let link = paths.plugins.appendingPathComponent(id.rawValue)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) {
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                if realPath(link.path) == target {
                    return Linked(link: link, target: target, wasThere: true)
                }
                let other = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? "somewhere else"
                throw Refusal(description: "\(link.path) is already a link, to \(other); take it away first "
                              + "(rm \(link.path) -- that takes the link, never what it points at)", isUsage: false)
            }
            throw Refusal(description: "\(link.path) is already there, a plugin folder uDeck did not install; move it "
                          + "out of the way first", isUsage: false)
        }

        do {
            try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        } catch {
            throw Refusal(description: "could not link \(link.path): \(error)", isUsage: false)
        }
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
            throw Refusal(description: "\(file.path) is not the list of installed plugins uDeck writes "
                          + (document.problems.first.map { "(it \($0))" } ?? "")
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
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
