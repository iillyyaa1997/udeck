#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import UDeckPluginFormat

/// `pin`: a plugin repository's lock file (`PluginLock`), written for one
/// release of uDeck, or held to it.
extension Command {
    static func pin(_ arguments: [String], environment: [String: String], here: String,
                    fetching: (any ReleaseFetching)?, output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        let parsed: Parsed
        let wanted: ReleasePin.Wanted?
        do {
            parsed = try parse(arguments, flags: ["--check"], values: ["--version", "--repo"])
            guard parsed.operands.isEmpty else {
                throw UsageError(message: "pin takes no operands; the repository is --repo <path>")
            }
            wanted = try release(parsed.values["--version"])
            if parsed.values["--repo"]?.isEmpty == true { throw UsageError(message: "--repo names no folder") }
        } catch let error as UsageError {
            errors("udeck-plugin pin: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        RepositoryCheck.sweepTemporaryFolder()

        // The repository: --repo, or the one the current folder is in, as
        // `new` finds it — the folder that holds udeck-plugins.json.
        let repository: URL
        if let given = parsed.values["--repo"] {
            repository = absolute(given, from: here)
            guard isFile(repository.appendingPathComponent(RepositoryPassport.path)) else {
                errors("udeck-plugin pin: \(given) is not a plugin repository: it has no \(RepositoryPassport.path)")
                return 2
            }
        } else {
            guard let found = PluginTemplate.repositoryRoot(above: URL(fileURLWithPath: here)) else {
                errors("udeck-plugin pin: \(here) is in no plugin repository: neither it nor a folder above it holds "
                       + "\(RepositoryPassport.path) — run pin in one, or name it with --repo <path>")
                return 2
            }
            repository = found
        }
        let file = repository.appendingPathComponent(PluginLock.path)
        // Said as it was asked for: from --repo as given, from the current
        // folder when that is the repository's root, else in full.
        let shownFile: String
        if let given = parsed.values["--repo"] {
            shownFile = (FilePaths.endsWithSeparator(given) ? given : given + "/") + PluginLock.path
        } else if repository.path.utf8.elementsEqual(URL(fileURLWithPath: here).standardizedFileURL.path.utf8) {
            shownFile = PluginLock.path
        } else {
            shownFile = file.path
        }
        let check = parsed.flags.contains("--check")

        // What is there now, read as the CI will read it.
        var existing: [UInt8]?
        var current: Result<PluginLock, PluginLock.Problem>?
        if isFile(file) {
            guard let bytes = try? Data(contentsOf: file) else {
                errors("udeck-plugin pin: could not read \(shownFile)")
                return 2
            }
            existing = [UInt8](bytes)
            do {
                current = .success(try PluginLock.read([UInt8](bytes)))
            } catch let problem as PluginLock.Problem {
                current = .failure(problem)
            } catch {
                return 2
            }
        } else if FileManager.default.fileExists(atPath: file.path) {
            errors("udeck-plugin pin: \(shownFile) is there and is not a file")
            return 2
        }

        // Which release: the one asked for; with --check and none asked for,
        // the one the lock file names, so that a check of it does not turn red
        // because uDeck released again; else the latest.
        let asked: ReleasePin.Wanted
        if let wanted {
            asked = wanted
        } else if check {
            switch current {
            case .success(let lock)?:
                asked = .version(lock.version)
            case .failure(let problem)?:
                output("\(shownFile) \(problem.description): udeck-plugin pin writes it again")
                return 1
            case nil:
                output("there is no \(shownFile): udeck-plugin pin writes it")
                return 1
            }
        } else {
            asked = .latest
        }

        let source: ReleaseSource
        let pinned: ReleasePin.Pinned
        do {
            source = try ReleaseSource(environment: environment)
            pinned = try ReleasePin.pin(asked, from: source, fetching: fetching ?? Curl(environment: environment))
        } catch let problem as ReleaseSource.Problem {
            errors("udeck-plugin pin: \(problem.description)")
            return 2
        } catch let failure as ReleasePin.Failure {
            errors("udeck-plugin pin: \(failure.description)")
            return 2
        } catch {
            errors("udeck-plugin pin: \(error)")
            return 2
        }
        let lock = pinned.lock
        let image = "\(pinned.image)@\(lock.image)"
        let text = Array(lock.text.utf8)
        // Two files a place serves that agree with each other are not two
        // files GitHub published: a place other than GitHub can serve sums of
        // its own, and an image file to go with them.
        let elsewhere = source.isGitHub ? nil
            : "note: \(ReleaseSource.variable) is \(source.shown), not GitHub's releases: the lock file holds what "
                + "that place serves — check it against GitHub's release with udeck-plugin pin --check, "
                + "\(ReleaseSource.variable) unset, where GitHub can be reached"

        if check {
            if existing == text {
                output("\(shownFile) pins udeck-plugin \(lock.version) as its release has it: \(image)")
                if let elsewhere { output(elsewhere) }
                return 0
            }
            switch current {
            case .success(let held)?:
                output("\(shownFile) does not pin what release v\(lock.version) has:")
                for line in differences(held, lock) { output("  \(line)") }
            case .failure(let problem)?:
                output("\(shownFile) \(problem.description)")
            case nil:
                output("there is no \(shownFile)")
            }
            output("udeck-plugin pin --version \(lock.version) writes it as the release has it")
            return 1
        }

        if existing == text {
            output("\(shownFile) already pins udeck-plugin \(lock.version); unchanged")
            if let elsewhere { output(elsewhere) }
            return 0
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text).write(to: file, options: .atomic)
        } catch {
            errors("udeck-plugin pin: could not write \(shownFile): \(error)")
            return 2
        }
        if case .failure(let problem)? = current {
            output("note: \(shownFile) \(problem.description): written again as the release has it")
        }
        output("pinned udeck-plugin \(lock.version) in \(shownFile), from \(pinned.from)")
        for platform in PluginLock.platforms {
            output("  \(PluginLock.archive(platform, of: lock.version))  \(lock.archives[platform] ?? "")")
        }
        output("  image  \(image)")
        if let elsewhere { output(elsewhere) }
        return 0
    }

    /// `--version`: X.Y.Z, `latest`, or nothing.
    static func release(_ given: String?) throws -> ReleasePin.Wanted? {
        guard let given else { return nil }
        if given == "latest" { return .latest }
        guard let version = SemanticVersion(given), version.description.utf8.elementsEqual(given.utf8) else {
            let hint = given.utf8.first == UInt8(ascii: "v") ? " (the tag without its v)" : ""
            throw UsageError(message: "--version \(given) is not X.Y.Z\(hint) or latest")
        }
        return .version(version)
    }

    /// What `held` pins that `release` does not, one key to a line.
    static func differences(_ held: PluginLock, _ release: PluginLock) -> [String] {
        var lines: [String] = []
        if held.version != release.version {
            lines.append("version: \(held.version) here, \(release.version) in the release")
        }
        for platform in PluginLock.platforms where held.archives[platform] != release.archives[platform] {
            lines.append("\(platform): \(held.archives[platform] ?? "") here, \(release.archives[platform] ?? "") in the release")
        }
        if held.image != release.image {
            lines.append("image: \(held.image) here, \(release.image) in the release")
        }
        return lines
    }

    static func isFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }
}
