import Foundation

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
        case .malformedTranslation: false
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
    public let directory: URL
    public let folderName: String
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
        translations: [String: ManifestTranslation] = [:]
    ) {
        self.directory = directory
        self.folderName = folderName
        self.manifest = manifest
        self.executable = executable
        self.problems = problems
        self.translations = translations
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

    public init(searchPath: [String]) {
        self.searchPath = searchPath
    }

    /// `FileManager.default` is documented as safe to use concurrently for the
    /// read-only operations here. It is reached through a computed property
    /// rather than stored, because storing a non-Sendable class would force
    /// every type that owns a discovery to give up `Sendable` too.
    private var fileManager: FileManager { .default }

    /// Scans the plugins directory. A missing directory is an empty result, not
    /// an error: it is the normal state of a fresh install.
    public func scan(_ pluginsDirectory: URL) -> [DiscoveredPlugin] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: pluginsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(load)
    }

    /// Loads one plugin folder.
    public func load(_ directory: URL) -> DiscoveredPlugin {
        let folderName = directory.lastPathComponent
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil, problems: [.missingManifest])
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil,
                                    problems: [.unreadableManifest(error.localizedDescription)])
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: nil, executable: nil,
                                    problems: [.malformedManifest(Self.describe(error))])
        }

        let (translations, translationProblems) = loadTranslations(in: directory)

        var problems: [DiscoveryProblem] = translationProblems
        if manifest.id.rawValue != folderName {
            problems.append(.identifierMismatch(declared: manifest.id.rawValue, folder: folderName))
        }
        problems += manifest.problems().map(DiscoveryProblem.manifest)

        let resolved = resolveExecutable(manifest.run.first ?? "", in: directory)
        switch resolved {
        case .success(let url):
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: url, problems: problems,
                                    translations: translations)
        case .failure(let problem):
            problems.append(problem)
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: nil, problems: problems,
                                    translations: translations)
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
            entries = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            return ([:], [])
        }

        var translations: [String: ManifestTranslation] = [:]
        var problems: [DiscoveryProblem] = []

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = url.lastPathComponent
            guard let code = Self.languageCode(ofTranslationFile: file) else { continue }
            do {
                let decoded = try JSONDecoder().decode(
                    ManifestTranslation.self, from: try Data(contentsOf: url)
                )
                translations[code] = decoded
            } catch {
                problems.append(.malformedTranslation(file: file, detail: Self.describe(error)))
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

    /// A decoding error in terms a plugin author can act on: which field, and
    /// what was wrong with it.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing required field \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(let type, let context):
            return "field \(path(context)) should be \(type)"
        case .valueNotFound(let type, let context):
            return "field \(path(context)) is null but must be \(type)"
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
