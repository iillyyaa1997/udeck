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
    public let manifest: PluginManifest?
    public let executable: URL?
    public let problems: [DiscoveryProblem]

    public var id: String { folderName }
    public var isUsable: Bool { manifest != nil && executable != nil && problems.isEmpty }

    public init(
        directory: URL,
        folderName: String,
        manifest: PluginManifest?,
        executable: URL?,
        problems: [DiscoveryProblem]
    ) {
        self.directory = directory
        self.folderName = folderName
        self.manifest = manifest
        self.executable = executable
        self.problems = problems
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

        var problems: [DiscoveryProblem] = []
        if manifest.id.rawValue != folderName {
            problems.append(.identifierMismatch(declared: manifest.id.rawValue, folder: folderName))
        }
        problems += manifest.problems().map(DiscoveryProblem.manifest)

        let resolved = resolveExecutable(manifest.run.first ?? "", in: directory)
        switch resolved {
        case .success(let url):
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: url, problems: problems)
        case .failure(let problem):
            problems.append(problem)
            return DiscoveredPlugin(directory: directory, folderName: folderName,
                                    manifest: manifest, executable: nil, problems: problems)
        }
    }

    /// Turns `run[0]` into a real file.
    ///
    /// A path (absolute, or containing a slash) is resolved against the plugin's
    /// own folder, so a plugin can ship its own script without knowing where it
    /// was installed. A bare name is looked up on the configured search path,
    /// never on the environment's `PATH`: uDeck can be launched from Finder,
    /// from a shell or by launchd, and inheriting whichever `PATH` happened to
    /// be around makes a plugin work in one and fail in another.
    private func resolveExecutable(_ command: String, in directory: URL) -> Result<URL, DiscoveryProblem> {
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
