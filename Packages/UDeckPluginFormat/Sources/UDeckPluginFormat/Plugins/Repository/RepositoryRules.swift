#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A reason uDeck will not install a plugin from a repository, in terms the
/// operator can act on: which plugin, what is wrong, and what would fix it.
///
/// Carries values rather than sentences, so the settings window can say each
/// one in the operator's language (`Phrase.refusal`). Paths are the
/// repository's own — `plugins/uptime/uptime.sh` — because that is where the
/// author has to look.
public enum RepositoryRefusal: Equatable, Hashable, Sendable {
    // What the listing says, before anything is downloaded.

    /// Rule 1: the folder's name is not a plugin id.
    case folderNameNotAnID(folder: String)
    /// Rule 3: no `manifest.json` in the folder.
    case noManifest(path: String)
    /// Rule 3: the manifest could not be read as one.
    case manifestUnreadable(path: String, detail: String)
    /// Rule 3: the manifest's `id` is not the folder's name.
    case manifestIDMismatch(declared: String, folder: String)
    /// Rule 3: a problem the plugin contract names, other than the two below.
    case manifestProblem(id: String, detail: String)
    /// The manifest is written for a contract this uDeck does not speak.
    case apiNotSpoken(name: String, version: String, api: Int)
    /// The manifest's `minUDeck` is newer than this uDeck.
    case needsNewerUDeck(name: String, version: String, required: String, running: String)
    /// Rule 4: `version` is not `MAJOR.MINOR.PATCH`.
    case versionNotComparable(name: String, version: String)
    /// Rule 4: `minUDeck` is there and is not `MAJOR.MINOR.PATCH`.
    case minUDeckNotComparable(name: String, text: String)
    /// Rule 5: a relative `run[0]` names nothing in the folder.
    case producerMissing(path: String)
    /// Rule 5: a relative `run[0]` names a file not committed as executable.
    case producerNotExecutable(path: String)
    /// Rule 5: a relative `run[0]` leads out of the folder.
    case producerOutsideFolder(path: String)
    /// Rule 6: a symbolic link or a submodule.
    case linkOrSubmodule(path: String, isLink: Bool)
    /// Rule 7: a name uDeck will not write.
    case nameNotAllowed(path: String)
    /// Rule 7: two names in one folder that one Mac volume would take for one.
    case namesDifferOnlyInCase(path: String, other: String)
    /// Rule 8: more files or more bytes than a plugin may have.
    case tooLarge(id: String, bytes: Int, files: Int)
    /// Rule 8: one file larger than a plugin's file may be.
    case fileTooLarge(path: String, bytes: Int)
    /// Rule 8: folders nested deeper than a plugin's may be.
    case nestedTooDeep(path: String)
    /// The listing gave no size for a file, so rule 8 cannot be checked before
    /// downloading it.
    case sizeNotListed(path: String)

    // What only the files themselves can show.

    /// A file hashed to something other than the blob the listing named.
    case arrivedDifferent(path: String, expected: String, got: String)
    /// The files are each right and still do not make up the listed folder.
    case folderDoesNotAddUp(id: String)
    /// Rule 9: a Git LFS pointer, which uDeck would install instead of the file.
    case lfsPointer(path: String)
    /// A file arrived larger than the listing said it would be.
    case arrivedLarger(path: String, bytes: Int)
    /// The folder fails the checks every folder gets — the same text a folder
    /// dropped in by hand would get.
    case failsTheUsualChecks(id: String, detail: String)
    /// The staged manifest's version is not the one the catalogue showed.
    case notTheVersionShown(id: String, shown: String, arrived: String)
    /// A folder appeared at `plugins/<id>` while the install was running.
    case folderAppeared(id: String)
}

extension RepositoryRefusal {
    /// The refusal in English: which plugin, what is wrong, and what would fix
    /// it, in the words of docs/plugin-repository.md where it has them.
    ///
    /// What a command line prints. uDeck's settings window says the same in the
    /// operator's language (`Phrase.catalogueRefusal`), and in English it says
    /// exactly this.
    public var message: String {
        switch self {
        case .folderNameNotAnID(let folder):
            "plugins/\(folder) is not a plugin id: lowercase letters, digits, \".\", \"_\" and \"-\", at most 64, starting with a letter or a digit."
        case .noManifest(let path): "\(path) is missing; a plugin folder needs one."
        case .manifestUnreadable(let path, let detail): "\(path) is not a valid manifest: \(detail)"
        case .manifestIDMismatch(let declared, let folder):
            "The manifest in plugins/\(folder) says its id is \"\(declared)\"; it has to be the folder's name."
        case .manifestProblem(let id, let detail): "\(id): \(detail)"
        case .apiNotSpoken(let name, let version, let api):
            "\(name) \(version) is written for plugin contract api \(api); this uDeck speaks api \(PluginAPI.current). Update uDeck to install it."
        case .needsNewerUDeck(let name, let version, let required, let running):
            "\(name) \(version) needs uDeck \(required) or later; this is uDeck \(running). Update uDeck (Settings → About) to install it."
        case .versionNotComparable(let name, let version):
            "\(name)'s version \"\(version)\" is not MAJOR.MINOR.PATCH, so uDeck cannot tell it from another version; it cannot be installed from a repository."
        case .minUDeckNotComparable(let name, let text):
            "\(name)'s minUDeck \"\(text)\" is not MAJOR.MINOR.PATCH, so uDeck cannot tell which release it needs; it cannot be installed from a repository."
        case .producerMissing(let path): "\(path) is what the manifest runs, and the repository does not have it."
        case .producerNotExecutable(let path):
            "\(path) is not committed as executable (git mode 100755), and uDeck takes the bit from the repository; commit it with chmod +x."
        case .producerOutsideFolder(let path): "\(path) leads out of the plugin's folder."
        case .linkOrSubmodule(let path, let isLink):
            "\(path) is a \(isLink ? "symbolic link" : "submodule"); a plugin from a repository may contain only files and folders."
        case .nameNotAllowed(let path):
            "\(path): names may use only letters, digits, \".\", \"_\" and \"-\", and may not start with \".\""
        case .namesDifferOnlyInCase(let path, let other):
            "\(path) and \(other) differ only in letter case, and a Mac's disk takes them for one file."
        case .tooLarge(let id, let bytes, let files):
            "\(id) is \(ByteCount.text(bytes, kilo: "KB", mega: "MB")) in \(files) files; uDeck installs plugins of up to 10 MB and \(RepositoryRules.maximumFiles) files."
        case .fileTooLarge(let path, let bytes):
            "\(path) is \(ByteCount.text(bytes, kilo: "KB", mega: "MB")); one file of a plugin may be up to 5 MB."
        case .nestedTooDeep(let path): "\(path) is nested more than \(RepositoryRules.maximumDepth) folders deep."
        case .sizeNotListed(let path): "The repository lists no size for \(path)."
        case .arrivedDifferent(let path, let expected, let got):
            "\(path) arrived different from what the repository lists (expected \(expected), got \(got)); nothing was installed."
        case .folderDoesNotAddUp(let id):
            "The files of \(id) do not add up to the folder the repository lists; nothing was installed."
        case .lfsPointer(let path):
            "\(path) is a Git LFS pointer, not the file; uDeck does not fetch LFS content."
        case .arrivedLarger(let path, _):
            "\(path) arrived larger than the repository lists; nothing was installed."
        case .failsTheUsualChecks(_, let detail): detail
        case .notTheVersionShown(let id, let shown, let arrived):
            "\(id) arrived as \(arrived), not the \(shown) the catalogue showed; nothing was installed. Check again."
        case .folderAppeared(let id):
            "A folder named \(id) appeared in the plugins folder while uDeck was installing; nothing was changed."
        }
    }
}

/// The rules a plugin folder in a repository is held to by uDeck at install
/// time: rules 1–8 of docs/plugin-repository.md, checked against the listing
/// alone, and the manifest checks a catalogue row makes before it offers
/// Install. Everything here is decided before a single file of the plugin is
/// downloaded.
///
/// Refusals, not warnings: each one is something that would make an installed
/// folder unsafe, different from what the repository says it is, or impossible
/// to update. What only makes a plugin hard to review is the repository
/// check's business, and uDeck neither refuses nor reports it.
public enum RepositoryRules {
    public static let maximumFiles = 200
    public static let maximumBytes = 10 * 1024 * 1024
    public static let maximumFileBytes = 5 * 1024 * 1024
    public static let maximumDepth = 8
    public static let maximumNameBytes = 255

    /// What a catalogue row knows about one plugin: its manifest, when it could
    /// be read, and every reason it cannot be installed here — empty when it can.
    public struct Verdict: Equatable, Sendable {
        public var manifest: PluginManifest?
        public var refusals: [RepositoryRefusal]

        public var isInstallable: Bool { manifest != nil && refusals.isEmpty }
    }

    /// Checks one plugin folder of a listing, and its manifest's bytes.
    ///
    /// `manifest` is nil when the manifest could not be fetched or is not in
    /// the listing. `udeck` is this uDeck's own version; nil skips the
    /// `minUDeck` comparison, as discovery does.
    public static func check(
        folder: String,
        listing: PluginListing,
        manifest data: Data?,
        udeck: SemanticVersion?
    ) -> Verdict {
        var refusals: [RepositoryRefusal] = []
        let base = "\(CommitListing.pluginsFolder)/\(folder)"

        if PluginIdentifier(rawValue: folder) == nil {
            refusals.append(.folderNameNotAnID(folder: folder))
        }
        refusals += listingRefusals(folder: folder, listing: listing)

        let manifestPath = "\(base)/\(PluginDiscovery.manifestFilename)"
        guard listing.file(at: PluginDiscovery.manifestFilename) != nil else {
            refusals.append(.noManifest(path: manifestPath))
            return Verdict(manifest: nil, refusals: refusals)
        }
        guard let data else {
            refusals.append(.manifestUnreadable(path: manifestPath, detail: "it could not be fetched"))
            return Verdict(manifest: nil, refusals: refusals)
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            refusals.append(.manifestUnreadable(path: manifestPath, detail: PluginDiscovery.describe(error, in: data)))
            return Verdict(manifest: nil, refusals: refusals)
        }
        refusals += manifestRefusals(manifest, folder: folder, listing: listing, udeck: udeck)
        return Verdict(manifest: manifest, refusals: refusals)
    }

    /// Rules 5 and the manifest checks, for a manifest that decoded.
    public static func manifestRefusals(
        _ manifest: PluginManifest,
        folder: String,
        listing: PluginListing,
        udeck: SemanticVersion?
    ) -> [RepositoryRefusal] {
        var refusals: [RepositoryRefusal] = []
        let base = "\(CommitListing.pluginsFolder)/\(folder)"
        let name = Blank.isBlank(manifest.name) ? folder : manifest.name

        // The two that decide whether it can run here at all go first: they
        // are the first reason a row shows.
        let supported = PluginAPI.oldestSupported ... PluginAPI.current
        if !supported.contains(manifest.api) {
            refusals.append(.apiNotSpoken(name: name, version: manifest.version, api: manifest.api))
        }
        if let text = manifest.minUDeck {
            if let required = SemanticVersion(text) {
                if let udeck, required > udeck {
                    refusals.append(.needsNewerUDeck(name: name, version: manifest.version,
                                                     required: required.description, running: udeck.description))
                }
            } else {
                refusals.append(.minUDeckNotComparable(name: name, text: text))
            }
        }
        if SemanticVersion(manifest.version) == nil {
            refusals.append(.versionNotComparable(name: name, version: manifest.version))
        }
        if manifest.id.rawValue != folder {
            refusals.append(.manifestIDMismatch(declared: manifest.id.rawValue, folder: folder))
        }
        for problem in manifest.problems(udeck: udeck) {
            switch problem {
            case .unsupportedAPI, .needsNewerUDeck: continue
            default: refusals.append(.manifestProblem(id: folder, detail: problem.description))
            }
        }

        // Rule 5: a producer shipped in the folder has to be in the listing,
        // and committed as executable — git carries the bit, and uDeck
        // restores it on install from the mode, not from anything on disk.
        if let command = manifest.run.first, command.contains("/"), !command.hasPrefix("/") {
            switch relativePath(command) {
            case .none:
                refusals.append(.producerOutsideFolder(path: "\(base)/\(command)"))
            case .some(let path):
                let entry = listing.entries.first { $0.path == path }
                switch entry?.kind {
                case .none, .folder?:
                    refusals.append(.producerMissing(path: "\(base)/\(path)"))
                case .file?:
                    refusals.append(.producerNotExecutable(path: "\(base)/\(path)"))
                case .executable?:
                    break
                case .link?, .submodule?, .other?:
                    // Already refused by rule 6, with the reason that matters.
                    break
                }
            }
        }
        return refusals
    }

    /// Rules 6, 7 and 8 — what the listing alone shows.
    public static func listingRefusals(folder: String, listing: PluginListing) -> [RepositoryRefusal] {
        var refusals: [RepositoryRefusal] = []
        let base = "\(CommitListing.pluginsFolder)/\(folder)"
        var namesByParent: [String: [String: String]] = [:]

        for entry in listing.entries.sorted(by: { $0.path < $1.path }) {
            let path = "\(base)/\(entry.path)"
            switch entry.kind {
            case .link: refusals.append(.linkOrSubmodule(path: path, isLink: true))
            case .submodule: refusals.append(.linkOrSubmodule(path: path, isLink: false))
            case .other: refusals.append(.linkOrSubmodule(path: path, isLink: false))
            case .file, .executable, .folder: break
            }

            // Each folder is listed as an entry of its own, so the last part
            // of every path is every name there is, each checked once.
            let components = entry.components
            if let last = components.last, !isAllowedName(last) {
                refusals.append(.nameNotAllowed(path: path))
            }
            let parent = components.dropLast().joined(separator: "/")
            if let last = components.last {
                let folded = last.lowercased()
                if let other = namesByParent[parent]?[folded], other != last {
                    let otherPath = parent.isEmpty ? "\(base)/\(other)" : "\(base)/\(parent)/\(other)"
                    refusals.append(.namesDifferOnlyInCase(path: path, other: otherPath))
                } else {
                    namesByParent[parent, default: [:]][folded] = last
                }
            }

            // Depth counts the folders a file sits in: `a/b/c.sh` is two deep.
            let depth = entry.kind == .folder ? components.count : components.count - 1
            if depth > maximumDepth {
                refusals.append(.nestedTooDeep(path: path))
            }
            if entry.isFile {
                if let size = entry.size {
                    if size > maximumFileBytes { refusals.append(.fileTooLarge(path: path, bytes: size)) }
                } else {
                    refusals.append(.sizeNotListed(path: path))
                }
            }
        }

        let files = listing.files
        let bytes = listing.totalBytes
        if files.count > maximumFiles || bytes > maximumBytes {
            refusals.append(.tooLarge(id: folder, bytes: bytes, files: files.count))
        }
        return refusals
    }

    /// Rule 7 for one name: `A–Z a–z 0–9 . _ -`, not starting with `.`, at most
    /// 255 bytes. ASCII, because a name in another script is stored in different
    /// Unicode forms by different volumes, and a name that changed bytes on
    /// disk no longer matches its hash.
    public static func isAllowedName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameBytes, !name.hasPrefix(".") else { return false }
        return name.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// A relative `run[0]` as a path inside the folder — `./uptime.sh` is
    /// `uptime.sh` — or nil when it climbs out of the folder.
    public static func relativePath(_ command: String) -> String? {
        var parts: [String] = []
        for part in command.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// What a Git LFS pointer starts with. uDeck would install the three-line
    /// pointer rather than the file, so one stops the install.
    public static let lfsPointerPrefix = Data("version https://git-lfs.github.com/spec/v1\n".utf8)

    public static func isLFSPointer(_ data: Data) -> Bool {
        data.count < 1024 && data.starts(with: lfsPointerPrefix)
    }
}
