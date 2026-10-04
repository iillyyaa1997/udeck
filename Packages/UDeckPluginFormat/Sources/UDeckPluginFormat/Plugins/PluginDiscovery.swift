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

/// Why uDeck does not follow a link in its plugins folder.
///
/// A link there is a folder an author works on somewhere else
/// (`udeck-plugin link`), and it is followed to that folder and nowhere
/// else: one step, to a folder outside uDeck's own.
public enum LinkRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// It points at nothing: the folder was moved, renamed or is on a volume
    /// that is not mounted.
    case leadsNowhere(String)
    /// It points at something that is not a folder.
    case notAFolder(String)
    /// It points at another link. One step only: a chain is somebody's
    /// arrangement uDeck cannot tell the end of, and a link to itself is one.
    case toALink(String)
    /// Following it goes round in a circle somewhere on the way.
    case circle(String)
    /// It leads into uDeck's own folder — its plugins, its caches, its logs —
    /// where uDeck writes and deletes, and a plugin's folder must never be one
    /// of those.
    case insideUDeck(String)
    /// It leads to a folder that holds uDeck's own.
    case holdsUDeck(String)
    /// Where it points could not be read.
    case unreadable(String)

    public var description: String {
        switch self {
        case .leadsNowhere(let destination):
            "a link to \(destination), which is not there — moved, renamed, or on a disk that is not connected"
        case .notAFolder(let destination):
            "a link to \(destination), which is not a folder; a link here has to lead to a plugin folder"
        case .toALink(let destination):
            "a link to \(destination), which is itself a link; link the plugin folder itself"
        case .circle(let destination):
            "a link to \(destination), and following it goes round in a circle"
        case .insideUDeck(let destination):
            "a link to \(destination), inside uDeck's own folder, where uDeck writes and deletes; link a folder of your own"
        case .holdsUDeck(let destination):
            "a link to \(destination), which holds uDeck's own folder; link the plugin folder itself"
        case .unreadable(let detail):
            "a link whose target could not be read: \(detail)"
        }
    }
}

/// Something that stops a folder from being a usable plugin.
public enum DiscoveryProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case missingManifest
    case unreadableManifest(String)
    case malformedManifest(String)
    case identifierMismatch(declared: String, folder: String)
    case manifest(ManifestProblem)
    case executableMissing(path: String)
    case executableNotOnSearchPath(command: String, searchPath: [String])
    case executableOutsidePluginFolder(command: String)
    case executableNotExecutable(String)
    case malformedTranslation(file: String, detail: String)

    /// The entry in the plugins folder is a link uDeck does not follow.
    case linkNotFollowed(LinkRefusal)

    /// `version` is not `MAJOR.MINOR.PATCH`. A note, never a refusal: the
    /// contract allowed any string before repositories gave versions a meaning,
    /// and such a plugin keeps running with its grants keyed by that string. It
    /// only cannot be published in a repository until the version parses.
    case versionNotComparable(String)

    /// `minUDeck` is there and is not `MAJOR.MINOR.PATCH`, so there is nothing
    /// to hold the plugin to. A note rather than a refusal: a uDeck from before
    /// the field loaded this manifest, and the `api: 1` promise forbids
    /// refusing it now. A repository refuses it at install instead.
    case minUDeckNotComparable(String)

    public var description: String {
        switch self {
        case .missingManifest:
            "no manifest.json in this folder"
        case .unreadableManifest(let detail):
            "manifest.json could not be read: \(detail)"
        case .malformedManifest(let detail):
            "manifest.json is not valid: \(detail)"
        case .identifierMismatch(let declared, let folder):
            "manifest declares id \"\(declared)\" but sits in a folder named \"\(folder)\" — they must match, because the folder name is what the operator sees and what settings are keyed by"
        case .manifest(let problem):
            problem.description
        case .executableMissing(let path):
            "\(path) does not exist"
        case .executableNotOnSearchPath(let command, let searchPath):
            "\(command) was not found on \(searchPath.joined(separator: ":"))"
        case .executableOutsidePluginFolder(let command):
            "\(command) resolves outside the plugin folder, which a plugin is not allowed to do"
        case .executableNotExecutable(let path):
            "\(path) is not executable — try chmod +x"
        case .malformedTranslation(let file, let detail):
            "\(file) is not valid and was ignored: \(detail) — the plugin still works in the language manifest.json is written in"
        case .versionNotComparable(let version):
            "version \"\(version)\" is not MAJOR.MINOR.PATCH — fine for a folder of your own, required to publish it in a repository"
        case .minUDeckNotComparable(let text):
            "minUDeck \"\(text)\" is not MAJOR.MINOR.PATCH, so no uDeck release can be held to it and it was ignored — required to publish it in a repository"
        case .linkNotFollowed(let refusal):
            "this is \(refusal)"
        }
    }

    /// Whether this is a reason not to run the plugin.
    ///
    /// Nearly all of them are: a plugin with no manifest, or one whose command
    /// does not exist, cannot be run at all. A translation that will not parse
    /// is the exception — it costs the plugin one language and nothing else,
    /// and a plugin that stopped working because a translator left out a comma
    /// would be a far worse outcome than one that is briefly in English.
    public var isFatal: Bool {
        switch self {
        case .malformedTranslation, .versionNotComparable, .minUDeckNotComparable: false
        default: true
        }
    }
}

/// A folder under `~/.udeck/plugins/`, and what uDeck made of it.
///
/// A folder that failed to load is still returned rather than skipped. A plugin
/// that silently does not appear is a support question; a plugin that appears
/// with a legible reason next to it is a five-second fix.
public struct DiscoveredPlugin: Sendable, Equatable, Identifiable {
    /// Where the plugin's files are. For a linked folder, the folder the link
    /// led to when the plugins folder was read — with every link on the way
    /// resolved, so that what runs is the folder that was read, whatever the
    /// link is pointed at meanwhile, until the folder is read again.
    public let directory: URL
    /// Its name in the plugins folder, which its manifest's id has to be: for
    /// a linked folder, the link's name, whatever the folder it leads to is
    /// called.
    public let folderName: String

    /// The link in the plugins folder, `<home>/plugins/<id>`, when the plugin
    /// is a linked folder — an author's working copy, put there by
    /// `udeck-plugin link` or **Link a folder…** — and nil for a folder that
    /// is there itself. Removing or replacing a linked plugin acts on this
    /// link alone, never on `directory`.
    public let linkedAt: URL?

    /// Whether this is a linked folder.
    public var isLinked: Bool { linkedAt != nil }
    /// The manifest as the author wrote it. Everything uDeck *acts* on — what
    /// it runs, what it is allowed to do — is read from here and never from a
    /// translation.
    public let manifest: PluginManifest?
    public let executable: URL?
    public let problems: [DiscoveryProblem]

    /// What the plugin says in other languages, keyed by language code, from the
    /// `manifest.<code>.json` files beside the manifest. Only strings.
    public let translations: [String: ManifestTranslation]

    public var id: String { folderName }
    /// Whether uDeck will run it.
    ///
    /// Judged on the problems that stop it running, not on every problem there
    /// is — see `DiscoveryProblem.isFatal`. A plugin whose Russian file has a
    /// stray comma is a plugin with a note against it, not a plugin that is
    /// gone.
    public var isUsable: Bool {
        manifest != nil && executable != nil && !problems.contains(where: \.isFatal)
    }

    public init(
        directory: URL,
        folderName: String,
        manifest: PluginManifest?,
        executable: URL?,
        problems: [DiscoveryProblem],
        translations: [String: ManifestTranslation] = [:],
        linkedAt: URL? = nil
    ) {
        self.directory = directory
        self.folderName = folderName
        self.manifest = manifest
        self.executable = executable
        self.problems = problems
        self.translations = translations
        self.linkedAt = linkedAt
    }

    /// The manifest as the operator should read it.
    ///
    /// Falls back to the language the manifest itself is written in, field by
    /// field, so a plugin translated by halves shows the half that is done.
    /// Everything not a display string is untouched by construction — see
    /// `ManifestTranslation`.
    public func manifest(in language: String) -> PluginManifest? {
        guard let manifest else { return nil }
        guard let translation = translations[language.lowercased()] else { return manifest }
        return manifest.applying(translation)
    }
}

/// Finds plugins on disk.
public struct PluginDiscovery: Sendable {
    public static let manifestFilename = "manifest.json"

    private let searchPath: [String]

    /// The running uDeck's own version, which a manifest's `minUDeck` is held
    /// to. Told rather than read from the bundle, so tests can set it; nil when
    /// the running version does not parse, which skips that comparison rather
    /// than refusing every plugin that declares one.
    private let udeck: SemanticVersion?

    /// The running uDeck's version this discovery holds manifests to.
    public var udeckVersion: SemanticVersion? { udeck }

    public init(searchPath: [String], udeck: SemanticVersion? = nil) {
        self.searchPath = searchPath
        self.udeck = udeck
    }

    /// `FileManager.default` is documented as safe to use concurrently for the
    /// read-only operations here. It is reached through a computed property
    /// rather than stored, because storing a non-Sendable class would force
    /// every type that owns a discovery to give up `Sendable` too.
    private var fileManager: FileManager { .default }

    /// Scans the plugins directory of uDeck's folder. A missing directory is an
    /// empty result, not an error: it is the normal state of a fresh install.
    ///
    /// A folder in it is a plugin, and so is a link in it to a folder
    /// somewhere else — a linked folder (`udeck-plugin link`) — named after
    /// the link. A link is followed one step, to a folder outside uDeck's own
    /// (`LinkRefusal` says what else it can be, and the plugin is listed with
    /// that as its problem). What the folder it leads to holds is read by the
    /// same rules as any folder: a link *inside* it is what it always was — a
    /// command that resolves out of the folder is refused.
    public func scan(_ paths: UDeckPaths) -> [DiscoveredPlugin] {
        scan(paths.plugins, udeckFolder: paths.root)
    }

    /// `scan(_:)` of the plugins folder `pluginsDirectory`, whose uDeck folder
    /// — which a link may not lead into — is the folder above it.
    public func scan(_ pluginsDirectory: URL) -> [DiscoveredPlugin] {
        scan(pluginsDirectory, udeckFolder: pluginsDirectory.deletingLastPathComponent())
    }

    private func scan(_ pluginsDirectory: URL, udeckFolder: URL) -> [DiscoveredPlugin] {
        let entries: [URL]
        do {
            entries = try visibleEntries(of: pluginsDirectory)
        } catch {
            return []
        }

        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { entry -> DiscoveredPlugin? in
                switch kind(of: entry) {
                case .typeDirectory?:
                    return load(entry)
                case .typeSymbolicLink?:
                    switch Self.follow(entry, udeckFolder: udeckFolder) {
                    case .success(let target):
                        return load(target, named: entry.lastPathComponent, linkedAt: entry)
                    case .failure(let refusal):
                        return DiscoveredPlugin(directory: entry, folderName: entry.lastPathComponent, manifest: nil,
                                                executable: nil, problems: [.linkNotFollowed(refusal)], linkedAt: entry)
                    }
                default:
                    return nil
                }
            }
    }

    /// What is in `directory`, less what the platform calls hidden.
    ///
    /// On a Mac that is Foundation's answer, as it always was: a name starting
    /// with `.`, and anything flagged hidden. Without Foundation's resource
    /// values — the Linux build — it is the name alone, which is all Linux
    /// means by hidden.
    private func visibleEntries(of directory: URL) throws -> [URL] {
        #if canImport(FoundationEssentials)
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
        #else
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles])
        #endif
    }

    /// What `url` is itself — a link, not what it leads to.
    private func kind(of url: URL) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// The folder a link in the plugins folder leads to, as an absolute path
    /// with every link on the way resolved — or why it is not followed.
    ///
    /// Asked of the disk each time the plugins folder is read: a link an
    /// author points elsewhere is a different plugin folder from then on.
    public static func follow(_ link: URL, udeckFolder: URL) -> Result<URL, LinkRefusal> {
        let manager = FileManager.default
        let destination: String
        do {
            destination = try manager.destinationOfSymbolicLink(atPath: link.path)
        } catch {
            return .failure(.unreadable(explain(error)))
        }
        // As the system reads it: a relative destination from the folder the
        // link is in. Absolute by its first byte: `/` and a combining mark
        // after it are one Character, and still an absolute path.
        let pointed = destination.utf8.first == UInt8(ascii: "/")
            ? destination
            : link.deletingLastPathComponent().path + "/" + destination
        // What the destination names itself, asked of its last name as
        // written: `hop/` and `hop/.` are `hop` — a link — and `lstat` with
        // the slash still on follows it to whatever it leads to.
        let found: FileAttributeType?
        do {
            found = try manager.attributesOfItem(atPath: Self.lastNameItself(pointed))[.type] as? FileAttributeType
        } catch {
            return .failure(FilePaths.real(pointed).failed == ELOOP ? .circle(destination) : .leadsNowhere(destination))
        }
        switch found {
        case .typeSymbolicLink?:
            return .failure(.toALink(destination))
        case .typeDirectory?:
            break
        default:
            return .failure(.notAFolder(destination))
        }
        let resolved = FilePaths.real(pointed)
        guard let target = resolved.path else {
            return .failure(resolved.failed == ELOOP ? .circle(destination) : .leadsNowhere(destination))
        }
        if let home = FilePaths.real(udeckFolder.path).path {
            if FilePaths.contains(home, target) { return .failure(.insideUDeck(destination)) }
            if FilePaths.contains(target, home) { return .failure(.holdsUDeck(destination)) }
        }
        return .success(URL(fileURLWithPath: target, isDirectory: true))
    }

    /// `path` without the slashes and `.` names at its end — `hop/`, `hop//`,
    /// `hop/.`, `hop/./` are all `hop` — so that `lstat` looks at the last name
    /// itself rather than through it. `/` stays `/`. By bytes: the names
    /// taken off are ASCII, and what is left is the path as it was written.
    static func lastNameItself(_ path: String) -> String {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        var bytes = Array(path.utf8)
        while bytes.count > 1 {
            if bytes.last == slash {
                bytes.removeLast()
            } else if bytes.last == dot, bytes[bytes.count - 2] == slash {
                bytes.removeLast()
            } else {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Loads one plugin folder.
    public func load(_ directory: URL) -> DiscoveredPlugin {
        load(directory, named: directory.lastPathComponent, linkedAt: nil)
    }

    /// Loads the plugin folder `directory` under the name `folderName` it has
    /// in the plugins folder — a link's, when `linkedAt` is the link that led
    /// there.
    public func load(_ directory: URL, named folderName: String, linkedAt: URL?) -> DiscoveredPlugin {
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil, problems: [.missingManifest], linkedAt: linkedAt)
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil,
                                    problems: [.unreadableManifest(Self.explain(error))], linkedAt: linkedAt)
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil,
                                    problems: [.malformedManifest(Self.describe(error, in: data, document: "the manifest"))],
                                    linkedAt: linkedAt)
        }

        let (translations, translationProblems) = loadTranslations(in: directory)

        var problems: [DiscoveryProblem] = translationProblems
        if manifest.id.rawValue != folderName {
            problems.append(.identifierMismatch(declared: manifest.id.rawValue, folder: folderName))
        }
        problems += manifest.problems(udeck: udeck).map(DiscoveryProblem.manifest)
        if SemanticVersion(manifest.version) == nil {
            problems.append(.versionNotComparable(manifest.version))
        }
        if let minUDeck = manifest.minUDeck, SemanticVersion(minUDeck) == nil {
            problems.append(.minUDeckNotComparable(minUDeck))
        }

        let resolved = resolveExecutable(manifest.run.first ?? "", in: directory)
        switch resolved {
        case .success(let url):
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: url, problems: problems,
                                    translations: translations, linkedAt: linkedAt)
        case .failure(let problem):
            problems.append(problem)
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: nil, problems: problems,
                                    translations: translations, linkedAt: linkedAt)
        }
    }

    /// Reads every `manifest.<code>.json` beside the manifest.
    ///
    /// A language uDeck does not itself speak is kept rather than rejected: the
    /// plugin was translated by somebody, and the day uDeck learns that language
    /// the translation is already there. A file that will not parse costs its
    /// own language and is reported — the plugin still works in the language its
    /// manifest is written in, and a plugin that vanished because a translator
    /// left out a comma would be the worse outcome by far.
    private func loadTranslations(
        in directory: URL
    ) -> ([String: ManifestTranslation], [DiscoveryProblem]) {
        let entries: [URL]
        do {
            entries = try visibleEntries(of: directory)
        } catch {
            return ([:], [])
        }

        var translations: [String: ManifestTranslation] = [:]
        var problems: [DiscoveryProblem] = []

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = url.lastPathComponent
            guard let code = Self.languageCode(ofTranslationFile: file) else { continue }
            var text: Data?
            do {
                text = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(ManifestTranslation.self, from: text ?? Data())
                translations[code] = decoded
            } catch {
                let detail = Self.describe(error, in: text, document: "the translation")
                problems.append(.malformedTranslation(file: file, detail: detail))
            }
        }
        return (translations, problems)
    }

    /// The language a `manifest.<code>.json` is for, or `nil` if the name is not
    /// one of those.
    ///
    /// Two or three letters, and an optional region after a dash — the shape
    /// ISO 639 codes actually come in.
    ///
    /// Strictness here is not pedantry. "letters, any number of them" accepts
    /// `manifest.backup.json`, and it did: a file somebody left lying about
    /// became a language uDeck claimed to speak, and then reported as broken
    /// because it was never a translation to begin with.
    static func languageCode(ofTranslationFile file: String) -> String? {
        guard file.hasPrefix("manifest."), file.hasSuffix(".json") else { return nil }
        let middle = String(file.dropFirst("manifest.".count).dropLast(".json".count))
        guard !middle.isEmpty else { return nil }

        let parts = middle.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        guard let language = parts.first,
              (2 ... 3).contains(language.count),
              language.allSatisfy(\.isLetter) else { return nil }
        if parts.count == 2 {
            let region = parts[1]
            guard (2 ... 8).contains(region.count),
                  region.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        }
        return middle.lowercased()
    }

    /// Turns `run[0]` into a real file.
    ///
    /// A path (absolute, or containing a slash) is resolved against the plugin's
    /// own folder, so a plugin can ship its own script without knowing where it
    /// was installed. A bare name is looked up on the configured search path,
    /// never on the environment's `PATH`: uDeck can be launched from Finder,
    /// from a shell or by launchd, and inheriting whichever `PATH` happened to
    /// be around makes a plugin work in one and fail in another.
    /// Public because a card's action is resolved the same way and used to be
    /// resolved by a second copy of these rules, which had drifted: that one
    /// compared paths lexically, so a plugin shipping `tools/refresh` as a
    /// symlink out of its folder got the operator's consent for one file and
    /// ran another. One set of rules, one place.
    public func resolveExecutable(_ command: String, in directory: URL) -> Result<URL, DiscoveryProblem> {
        guard !command.isEmpty else { return .failure(.executableMissing(path: "(empty)")) }

        func check(_ url: URL) -> Result<URL, DiscoveryProblem>? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            guard fileManager.isExecutableFile(atPath: url.path) else {
                return .failure(.executableNotExecutable(url.path))
            }
            return .success(url.standardizedFileURL)
        }

        if command.hasPrefix("/") {
            return check(URL(fileURLWithPath: command)) ?? .failure(.executableMissing(path: command))
        }

        if command.contains("/") {
            // A relative path must stay inside the plugin's folder: `../../ssh`
            // would let a manifest reach anywhere on disk while still looking
            // like a self-contained plugin.
            //
            // Symlinks have to be resolved for that check to mean anything.
            // `standardizedFileURL` only collapses `..` lexically, so a plugin
            // shipping `bin -> /bin` and running `./bin/sh` passed a check that
            // was, at that point, decoration.
            let resolved = directory.appendingPathComponent(command)
                .standardizedFileURL.resolvingSymlinksInPath()
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else {
                return .failure(.executableOutsidePluginFolder(command: command))
            }
            return check(resolved) ?? .failure(.executableMissing(path: resolved.path))
        }

        for entry in searchPath {
            let url = URL(fileURLWithPath: entry).appendingPathComponent(command)
            if let result = check(url) { return result }
        }
        return .failure(.executableNotOnSearchPath(command: command, searchPath: searchPath))
    }

    /// Why a file could not be read, in a sentence: Foundation's own, where
    /// there is Foundation to say it.
    static func explain(_ error: any Error) -> String {
        #if canImport(FoundationEssentials)
        return "\(error)"
        #else
        return error.localizedDescription
        #endif
    }

    /// A decoding error in terms a plugin author can act on: which field, and
    /// what was wrong with it — in the words of the JSON, never the names of
    /// the Swift types it was being read into. `document` is what the whole
    /// text is called where no field is to blame — "the manifest", "the
    /// translation": a list where an object belongs is said of it, not of a
    /// field with no name.
    ///
    /// `data`, when the caller still has it, is what the decoder read: a
    /// decoder that does not say which number it could not hold — outside
    /// Apple's own Foundation it attaches no reason at all — is answered from
    /// the text itself.
    public static func describe(_ error: any Error, in data: Data? = nil, document: String) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "\"\(field(context.codingPath + [key]))\" is required"
        case .typeMismatch(let type, let context):
            let found = found(in: context.debugDescription).map { ", not \($0)" } ?? ""
            return "\(name(context.codingPath, document)) must be \(kind(of: type))\(found)"
        case .valueNotFound(let type, let context):
            return "\(name(context.codingPath, document)) must be \(kind(of: type)), not null"
        case .dataCorrupted(let context):
            return corrupted(context, in: data)
        @unknown default:
            return "\(error)"
        }
    }

    /// A field in quotes, or the whole document when the path is empty.
    static func name(_ path: [any CodingKey], _ document: String) -> String {
        path.isEmpty ? document : "\"\(field(path))\""
    }

    /// A field as a manifest spells it: `settings[0].type`, `window.minWidth`.
    static func field(_ path: [any CodingKey]) -> String {
        var text = ""
        for key in path {
            // An element of a list is a key named "Index 3" whose number is 3.
            if let index = key.intValue, key.stringValue == "Index \(index)" {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return text
    }

    /// What a value of `type` is, in the words of a message.
    static func kind(of type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type:
            return "a whole number"
        case is Double.Type, is Float.Type: return "a number"
        default:
            let name = "\(type)"
            if name.hasPrefix("Array<") || name.hasPrefix("[") && !name.contains(":") { return "a list" }
            if name.hasPrefix("Dictionary<") || name.hasPrefix("[") { return "an object" }
            return "something else"
        }
    }

    /// What the decoder found instead, from its own sentence ("Expected to
    /// decode … but found an array instead."), in the words of a message — or
    /// nil when its sentence is not that one.
    static func found(in description: String) -> String? {
        guard let start = description.firstRange(of: "but found "),
              let end = description[start.upperBound...].firstRange(of: " instead") else {
            return nil
        }
        var found = description[start.upperBound ..< end.lowerBound]
        for article in ["a ", "an "] where found.hasPrefix(article) { found = found.dropFirst(article.count) }
        switch found {
        case "array": return "a list"
        case "dictionary": return "an object"
        case "string": return "a string"
        case "number": return "a number"
        case "bool", "boolean": return "true or false"
        case "null", "null value": return "null"
        default: return nil
        }
    }

    /// A value the decoder could not take. Its own sentence where uDeck's
    /// decoders wrote one; the decoder's where they did not, with the names
    /// of Swift types taken out.
    static func corrupted(_ context: DecodingError.Context, in data: Data? = nil) -> String {
        let place = context.codingPath.isEmpty ? nil : "\"\(field(context.codingPath))\""
        let said = context.debugDescription
        if said.hasPrefix("The given data was not valid JSON") {
            // A number the decoder cannot hold where it stands — 1.5 where a
            // whole number belongs, 1e400 in a field it reads — is reported
            // as JSON that is not valid, with no field; the sentence under it
            // names the number.
            let underlying = context.underlyingError.map { "\($0)" } ?? ""
            if let start = underlying.firstRange(of: "Number "),
               let end = underlying[start.upperBound...].firstRange(of: " is not representable") {
                return unreadable(String(underlying[start.upperBound ..< end.lowerBound]))
            }
            if let data, let number = unreadableNumber(in: data) {
                return unreadable(number)
            }
            return place.map { "\($0) is not valid JSON" } ?? "is not valid JSON"
        }
        // "Cannot initialize PluginKind from invalid String value frob"
        if said.hasPrefix("Cannot initialize "), let value = said.firstRange(of: " value ") {
            let text = said[value.upperBound...]
            return "\(place ?? "the value") is \"\(text)\", which is not one of the values it can have"
        }
        return place.map { "\($0): \(said)" } ?? said
    }

    /// The sentence for a number a decoder could not hold where it stands;
    /// `nil` names none.
    static func unreadable(_ number: String?) -> String {
        let which = number.map { "the number \($0)" } ?? "a number in it"
        return "\(which) cannot be read where it is: it is too large, or not a whole number where one belongs"
    }

    /// Which number in `data` a decoder would have choked on, when the text is
    /// JSON and only its numbers are in question. One too large for a `Double`
    /// is named; so is the only number that is not whole. With several of
    /// those, any one of them may be the field that wanted a whole number, so
    /// none is named — a wrong name is worse than none. `nil` when the text is
    /// not JSON for another reason.
    static func unreadableNumber(in data: Data) -> String?? {
        let document = StrictJSON.parse(Array(data))
        guard let value = document.value else {
            for problem in document.problems {
                if let tail = problem.firstRange(of: " is too large a number to read") {
                    let head = problem[..<tail.lowerBound]
                    return .some(head.split(separator: " ").last.map(String.init))
                }
            }
            return nil
        }
        var notWhole: [String] = []
        var pending = [value]
        while let next = pending.popLast() {
            switch next {
            case .number(let number) where number.wholeValue == nil: notWhole.append(number.literal)
            case .array(let items): pending.append(contentsOf: items)
            case .object(let object): pending.append(contentsOf: object.members.map(\.value))
            default: break
            }
        }
        if notWhole.isEmpty { return nil }
        return .some(notWhole.count == 1 ? notWhole[0] : nil)
    }
}
