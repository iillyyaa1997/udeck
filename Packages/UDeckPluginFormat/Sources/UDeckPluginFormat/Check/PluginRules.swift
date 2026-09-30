#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The rules for one plugin folder: 3–13 of docs/plugin-repository.md, 14–16
/// for the official repository, and 19.
///
/// What uDeck refuses is decided by uDeck's own code — `RepositoryRules`, the
/// rules a catalogue row and an install run — so that "the check passes" and
/// "uDeck installs it" cannot drift apart; this only says each refusal as a
/// finding. What only the repository check holds a plugin to is here.
enum PluginRules {
    static let archiveAttributes = ["export-ignore", "export-subst", "filter"]

    /// What an LFS pointer starts with. "hawser" is what the spec was called
    /// before it was Git LFS, and git-lfs still reads it. uDeck itself knows
    /// only the first, exactly as git-lfs writes it (`RepositoryRules.isLFSPointer`).
    static let lfsPrefixes = [Array("version https://git-lfs.github.com/spec/".utf8),
                              Array("version https://hawser.github.com/spec/".utf8)]

    /// Checks the plugin folder at `folder` in `tree`, whose name is `id`.
    static func check(_ folder: String, id: String, in tree: Tree, mode: CheckMode,
                      attributes: [String: [String: String]], report: inout CheckReport) {
        let entries = tree.under(folder)
        let top = Dictionary(tree.children(of: folder).map { ($0.name, $0) }) { first, _ in first }
        let listing = PluginListing(tree: tree.entries[folder]?.id ?? "", entries: entries.map {
            ListedEntry(path: String($0.path.dropFirst(folder.count + 1)), mode: $0.mode, sha: $0.id, size: $0.size)
        })

        listingRules(folder, id: id, listing: listing, tree: tree, report: &report)

        // Rule 9: a pointer instead of the file.
        for entry in entries {
            guard let content = tree.content(entry) else { continue }
            let isPointer = mode.strict ? lfsPrefixes.contains { content.starts(with: $0) }
                                        : RepositoryRules.isLFSPointer(Data(content))
            if isPointer {
                report.error("9", entry.path, "is a Git LFS pointer, not the file; uDeck does not fetch LFS content")
            }
        }
        if mode.strict, let entry = tree.entries[folder] {
            for entry in [entry] + entries { archiveAttributes(of: entry, attributes, &report) }
        }

        let manifest = mode.strict
            ? strictManifest(folder, id: id, top: top, tree: tree, report: &report)
            : installableManifest(folder, id: id, top: top, listing: listing, tree: tree, report: &report)

        guard mode.strict else { return }

        // Rule 10.
        if top["README.md"]?.isFile != true {
            report.error("10", folder + "/README.md", "is missing; it is what a reviewer and an installer read first")
        }

        // Rules 11 and 12, for translations.
        let translations = top.values.filter { $0.isFile && PluginDiscovery.languageCode(ofTranslationFile: $0.name) != nil }
            .sorted { $0.rawPath.lexicographicallyPrecedes($1.rawPath) }
        if translations.isEmpty {
            report.warning("11", folder, "has no manifest.<lang>.json; the plugin will show in English only")
        }
        var translated: [StrictJSON.Object] = []
        for entry in translations {
            guard let content = tree.content(entry) else { continue } // larger than rule 8 allows, and said there
            let document = StrictJSON.parse(content)
            for problem in document.problems { report.error("12", entry.path, problem) }
            guard let value = document.value else { continue }
            for problem in ManifestShape.translationProblems(of: value, manifest: manifest.decoded) {
                report.error("12", entry.path, problem)
            }
            if let object = value.object { translated.append(object) }
        }

        // Rule 13.
        for entry in entries where entry.mode == TreeEntry.executable {
            if let content = tree.content(entry), content.contains(0x0D) {
                report.error("13", entry.path, "is executable and contains a carriage return; with Windows line "
                             + "endings a script fails on a Mac with \"bad interpreter\"")
            }
        }

        // Rule 19.
        if let object = manifest.object {
            ContractFeatures.checkMinimumUDeck(object, translations: translated,
                                               path: folder + "/" + PluginDiscovery.manifestFilename, report: &report)
        }

        guard mode.official else { return }
        OfficialRules.textOnly(folder, entries: entries, tree: tree, report: &report)
        let author = OfficialRules.author(manifest.object, folder: folder, report: &report)
        OfficialRules.licence(folder, entry: top["LICENSE"], author: author, tree: tree, report: &report)
    }

    /// Rule 9, for one path: what `.gitattributes` sets that changes an archive.
    static func archiveAttributes(of entry: TreeEntry, _ attributes: [String: [String: String]],
                                  _ report: inout CheckReport) {
        for (attribute, value) in (attributes[entry.path] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let setting = value == "set" ? attribute : "\(attribute)=\(value)"
            report.error("9", entry.path, "has the attribute \(setting) from .gitattributes; export-ignore, "
                         + "export-subst and filter change what an archive of the repository holds")
        }
    }

    // MARK: - Rules 6, 7 and 8: uDeck's, from the listing

    static func listingRules(_ folder: String, id: String, listing: PluginListing, tree: Tree,
                             report: inout CheckReport) {
        // uDeck names paths `plugins/<id>/…`; here the folder may sit anywhere.
        let uDeckBase = "\(CommitListing.pluginsFolder)/\(id)"
        func here(_ path: String) -> String {
            path == uDeckBase ? folder : path.hasPrefix(uDeckBase + "/") ? folder + path.dropFirst(uDeckBase.count) : path
        }
        var links: [CheckFinding] = []
        var names: [CheckFinding] = []
        var sizes: [CheckFinding] = []
        var caseGroups: [String: [String: Set<String>]] = [:]
        var tooDeep: [String] = []
        func finding(_ rule: String, _ path: String, _ message: String) -> CheckFinding {
            CheckFinding(level: .error, rule: rule, path: path, message: message)
        }

        for refusal in RepositoryRules.listingRefusals(folder: id, listing: listing) {
            switch refusal {
            case .linkOrSubmodule(let path, let isLink):
                let entry = tree.entries[here(path)]
                let message = isLink ? "is a symbolic link; a plugin may contain only files and folders"
                    : entry?.kind == .other ? "is neither a file nor a folder; a plugin may contain only files and folders"
                    : "is a submodule -- a pointer to another repository, which uDeck would install as nothing"
                links.append(finding("6", here(path), message))
            case .nameNotAllowed(let path):
                let name = String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
                var reasons: [String] = []
                let characters = name.utf8.allSatisfy {
                    (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0)
                        || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
                }
                if name.isEmpty || !characters {
                    reasons.append("uses a character other than letters, digits, \".\", \"_\" and \"-\"")
                }
                if name.hasPrefix(".") { reasons.append("starts with \".\"") }
                if name.utf8.count > RepositoryRules.maximumNameBytes {
                    reasons.append("is longer than \(RepositoryRules.maximumNameBytes) bytes")
                }
                names.append(finding("7", here(path), "the name " + reasons.joined(separator: " and ")))
            case .namesDifferOnlyInCase(let path, let other):
                let parent = String(here(path).dropLast(path.split(separator: "/").last.map { $0.count + 1 } ?? 0))
                let group = String(path.split(separator: "/").last ?? "").lowercased()
                caseGroups[parent, default: [:]][group, default: []].formUnion([
                    String(path.split(separator: "/").last ?? ""), String(other.split(separator: "/").last ?? ""),
                ])
            case .tooLarge(_, let bytes, let files):
                if files > RepositoryRules.maximumFiles {
                    sizes.append(finding("8", folder, "holds \(files) files; at most \(RepositoryRules.maximumFiles)"))
                }
                if bytes > RepositoryRules.maximumBytes {
                    sizes.append(finding("8", folder, "is \(bytes) bytes in total; at most \(RepositoryRules.maximumBytes) (10 MiB)"))
                }
            case .fileTooLarge(let path, let bytes):
                sizes.append(finding("8", here(path), "is \(bytes) bytes; at most \(RepositoryRules.maximumFileBytes) (5 MiB) for one file"))
            case .nestedTooDeep(let path):
                tooDeep.append(here(path))
            case .sizeNotListed(let path):
                sizes.append(finding("8", here(path), "has no size in the listing, so its size cannot be checked"))
            default:
                continue
            }
        }
        for (parent, groups) in caseGroups.sorted(by: { $0.key < $1.key }) {
            for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
                names.append(finding("7", parent, "\(group.sorted().joined(separator: " and ")) differ only in letter case; "
                                     + "on a Mac they are one file"))
            }
        }
        // One finding for depth, at the first folder too deep: every file and
        // folder below it is too deep for the same reason.
        if let deepest = tree.ordered.first(where: { $0.kind == .tree && tooDeep.contains($0.path) }) ?? tooDeep.first.flatMap({ tree.entries[$0] }) {
            let depth = deepest.path.dropFirst(folder.count + 1).split(separator: "/").count
            sizes.append(finding("8", deepest.path, "is nested \(depth) folders deep; at most \(RepositoryRules.maximumDepth)"))
        }
        report.findings += links + names + sizes
    }

    // MARK: - Rules 3, 4 and 5

    /// What the manifest turned out to be.
    struct Manifest {
        /// The manifest as JSON, when it is an object.
        var object: StrictJSON.Object?
        /// The manifest as uDeck decodes it, when it does.
        var decoded: PluginManifest?
    }

    /// Rules 3, 4 and 5 as uDeck holds a plugin to them at install.
    static func installableManifest(_ folder: String, id: String, top: [String: TreeEntry], listing: PluginListing,
                                    tree: Tree, report: inout CheckReport) -> Manifest {
        let path = folder + "/" + PluginDiscovery.manifestFilename
        guard let entry = top[PluginDiscovery.manifestFilename], entry.isFile else {
            let present = top[PluginDiscovery.manifestFilename] != nil
            report.error("3", path, present ? "must be a file" : "is missing; every plugin folder has one, directly inside it")
            return Manifest()
        }
        guard let content = tree.content(entry) else { return Manifest() } // larger than rule 8 allows
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(content))
        } catch {
            report.error("3", path, "is not a manifest uDeck can read: \(PluginDiscovery.describe(error))")
            return Manifest()
        }
        let command = manifest.run.first ?? ""
        for refusal in RepositoryRules.manifestRefusals(manifest, folder: id, listing: listing, udeck: nil) {
            switch refusal {
            case .apiNotSpoken(_, _, let api):
                report.error("3", path, "it declares api \(api); uDeck speaks api \(PluginAPI.current)")
            case .manifestIDMismatch(let declared, _):
                report.error("3", path, "declares id \"\(declared)\" but sits in the folder \"\(id)\"; they must match")
            case .manifestProblem(_, let detail):
                report.error("3", path, detail)
            case .versionNotComparable(_, let version):
                report.error("4", path, versionMessage("version", version))
            case .minUDeckNotComparable(_, let text):
                report.error("4", path, versionMessage("minUDeck", text))
            case .producerOutsideFolder:
                report.error("5", path, "\"run\" starts with \"\(command)\", which climbs out of the plugin folder")
            case .producerMissing(let missing):
                report.error("5", path, "\"run\" starts with \"\(command)\", but \(relocated(missing, id, folder)) is not a file here")
            case .producerNotExecutable(let producer):
                let here = relocated(producer, id, folder)
                report.error("5", here, tree.commit == nil
                    ? "is what \"run\" starts with, but it is not executable -- chmod +x \(here)"
                    : "is what \"run\" starts with, but it is committed as 100644, not executable (100755) "
                        + "-- git update-index --chmod=+x \(here)")
            default:
                continue
            }
        }
        return Manifest(object: nil, decoded: manifest)
    }

    /// Rules 3, 4, 5 and 12 for the manifest, strictly: the JSON itself, every
    /// field's shape at once, then uDeck's own decoder and its problems.
    static func strictManifest(_ folder: String, id: String, top: [String: TreeEntry], tree: Tree,
                               report: inout CheckReport) -> Manifest {
        let path = folder + "/" + PluginDiscovery.manifestFilename
        guard let entry = top[PluginDiscovery.manifestFilename] else {
            report.error("3", path, "is missing; every plugin folder has one, directly inside it")
            return Manifest()
        }
        guard entry.isFile else {
            report.error("3", entry.path, "must be a file")
            return Manifest()
        }
        guard let content = tree.content(entry) else { return Manifest() } // larger than rule 8 allows
        let document = StrictJSON.parse(content)
        for problem in document.problems { report.error("3", path, problem) }
        guard let value = document.value else { return Manifest() }

        var result = Manifest(object: value.object)
        let wrong = ManifestShape.problems(of: value)
        for problem in wrong { report.error("3", path, problem) }
        if wrong.isEmpty {
            // What the shape does not cover, uDeck's decoder does — `restart`,
            // for one, which it reads whole or refuses, and which rule 12
            // below refuses anyway.
            do {
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(content))
                result.decoded = manifest
                if manifest.id.rawValue != id {
                    report.error("3", path, "declares id \"\(manifest.id.rawValue)\" but sits in the folder \"\(id)\"; "
                                 + "they must match")
                }
                let problems = manifest.problems()
                for problem in problems {
                    if case .unsupportedAPI(let declared, _) = problem {
                        report.error("3", path, "it declares api \(declared); uDeck speaks api \(PluginAPI.current)")
                    } else {
                        report.error("3", path, problem.description)
                    }
                }
                // A command of nothing but line breaks passes uDeck's own test,
                // which trims spaces only — and it would load a manifest like
                // that, as it always has — and then finds no program by that
                // name. The check calls it what it is.
                if !problems.contains(.emptyRunCommand), let command = manifest.run.first, PythonSpace.isBlank(command) {
                    report.error("3", path, ManifestProblem.emptyRunCommand.description)
                }
            } catch {
                report.error("3", path, "is not a manifest uDeck can read: \(PluginDiscovery.describe(error))")
            }
        }
        guard let object = value.object else { return result }

        // Rule 4.
        if let version = object.last("version")?.string, SemanticVersion(version) == nil {
            report.error("4", path, versionMessage("version", version))
        }
        if let minimum = object.last("minUDeck")?.string, SemanticVersion(minimum) == nil {
            report.error("4", path, versionMessage("minUDeck", minimum))
        }

        // Rule 5: a relative run[0] is a file in the folder, committed as
        // executable — and never a path that leaves the folder on its way,
        // even to come back (`sub/../../x/run.sh`), which uDeck refuses.
        if let command = object.last("run")?.array?.first?.string, command.contains("/"), !command.hasPrefix("/") {
            if let relative = RepositoryRules.relativePath(command) {
                let target = folder + "/" + relative
                let producer = tree.entries[target]
                if producer == nil || producer?.kind != .blob {
                    report.error("5", path, "\"run\" starts with \"\(command)\", but \(target) is not a file in this commit")
                } else if let producer, producer.mode != TreeEntry.executable {
                    report.error("5", producer.path, tree.commit == nil
                        ? "is what \"run\" starts with, but it is not executable -- chmod +x \(producer.path)"
                        : "is what \"run\" starts with, but it is committed as \(producer.mode), not executable (100755) "
                            + "-- git update-index --chmod=+x \(producer.path)")
                }
            } else {
                report.error("5", path, "\"run\" starts with \"\(command)\", which leaves the plugin folder on its way")
            }
        }

        // Rule 12.
        for field in ManifestShape.unknownFields(of: object) {
            let why = ContractFeatures.outsideTheContract.contains(field)
                ? "uDeck reads it only for resident plugins, which it does not run yet; leave it out"
                : "usually a typo, and uDeck ignores it"
            report.error("12", path, "has the field \"\(field)\", which the plugin contract does not define -- \(why)")
        }
        return result
    }

    static func versionMessage(_ field: String, _ text: String) -> String {
        field == "version"
            ? "\"version\" is \"\(text)\", which is not MAJOR.MINOR.PATCH (like 1.2.0: three whole numbers, no leading zeros, no suffix)"
            : "\"\(field)\" is \"\(text)\", which is not MAJOR.MINOR.PATCH"
    }

    /// A path uDeck named as `plugins/<id>/…`, where the folder is.
    static func relocated(_ path: String, _ id: String, _ folder: String) -> String {
        let base = "\(CommitListing.pluginsFolder)/\(id)"
        return path.hasPrefix(base + "/") ? folder + path.dropFirst(base.count) : path
    }
}
