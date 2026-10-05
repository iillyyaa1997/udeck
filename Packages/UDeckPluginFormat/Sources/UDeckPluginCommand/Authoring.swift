#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import UDeckPluginFormat

/// `new`, `run` and `link`: the commands an author works with, beside the
/// checks a repository's CI runs.
extension Command {
    // MARK: - new

    static func makePlugin(_ arguments: [String], environment: [String: String], here: String,
                           output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(arguments, flags: [], values: ["--name", "--author", "--description"])
            guard parsed.operands.count == 1 else {
                throw UsageError(message: parsed.operands.isEmpty ? "new needs the new plugin's id" : "new makes one plugin at a time")
            }
        } catch let error as UsageError {
            errors("udeck-plugin new: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        let request = PluginTemplate.Request(
            id: parsed.operands[0], name: parsed.values["--name"], author: parsed.values["--author"],
            description: parsed.values["--description"], start: URL(fileURLWithPath: here).standardizedFileURL,
            environment: environment)
        let made: PluginTemplate.Made
        do {
            made = try PluginTemplate.make(request)
        } catch let refusal as PluginTemplate.Refusal {
            errors("udeck-plugin new: \(refusal.description)")
            return refusal.isUsage ? 2 : 1
        } catch {
            errors("udeck-plugin new: \(error)")
            return 1
        }
        let shown = shown(made.folder, from: here)
        output("made \(shown): \(made.files.joined(separator: ", "))")
        for note in made.notes { output("note: \(note)") }
        output("""
            next:
              udeck-plugin check --strict \(shown)    every rule a repository's CI holds it to
              udeck-plugin run \(shown)               run it as uDeck does, and see what uDeck makes of it
            """)
        return 0
    }

    // MARK: - link

    static func linkPlugin(_ arguments: [String], environment: [String: String], here: String, homes: UserHomes,
                           output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(arguments, flags: [], values: ["--home"])
            guard parsed.operands.count == 1 else {
                throw UsageError(message: parsed.operands.isEmpty ? "link needs the plugin folder to link" : "link links one folder at a time")
            }
        } catch let error as UsageError {
            errors("udeck-plugin link: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        if let given = parsed.values["--home"], given.isEmpty {
            errors("udeck-plugin link: \(emptyHome)\n\n\(usage)")
            return 2
        }
        let home: URL
        if let given = parsed.values["--home"] {
            home = absolute(given, from: here)
        } else {
            switch udeckHome(environment: environment, here: here, homes: homes) {
            case .success(let found):
                home = found
            case .failure(let lost):
                errors("udeck-plugin link: \(lost.description); say where uDeck's folder is with --home")
                return 2
            }
        }
        let linked: PluginLink.Linked
        do {
            linked = try PluginLink.link(absolute(parsed.operands[0], from: here), home: home)
        } catch let refusal as PluginLink.Refusal {
            errors("udeck-plugin link: \(refusal.description)")
            return refusal.isUsage ? 2 : 1
        } catch {
            errors("udeck-plugin link: \(error)")
            return 1
        }
        output(linked.wasThere ? "already linked: \(linked.link.path) -> \(linked.target)"
                               : "linked \(linked.link.path) -> \(linked.target)")
        output("to undo it: rm \(PluginLink.shellQuoted(linked.link.path)) (the link goes; the folder it points at "
               + "stays as it is)")
        return 0
    }

    /// Said of `--home=` and `--home ""`: read as a path, nothing is the
    /// current folder, and a run or a link would make uDeck's folders in it.
    static let emptyHome = "--home is uDeck's folder, and an empty one names none"

    /// Why uDeck's folder could not be found.
    struct HomeNotFound: Error, CustomStringConvertible {
        var description: String
    }

    /// uDeck's folder, found the way uDeck finds it (`UDeckPaths.fromEnvironment`):
    /// `UDECK_HOME` when it is set and not empty, and `~/.udeck` otherwise.
    ///
    /// The home folder is the account's, as uDeck's Foundation answers it
    /// (`NSHomeDirectory()`, `UserHomes.account(in:)`): `CFFIXED_USER_HOME`
    /// when it is set, which Foundation reads first, then the account
    /// database — and `HOME` only when the database has no entry for the
    /// account, as Foundation falls back to it. Not `HOME` first: a shell
    /// started with another `HOME` — `sudo -E`, a test, a script — would link
    /// into a folder uDeck never reads.
    ///
    /// `~` at the start of `UDECK_HOME` is that home, and `~name` the home
    /// `NSString.expandingTildeInPath` reads for it — `CFFIXED_USER_HOME` when
    /// it is set, the account `name`'s otherwise
    /// (`UserHomes.account(named:in:)`); a relative one is read from `here`.
    static func udeckHome(environment: [String: String], here: String, homes: UserHomes) -> Result<URL, HomeNotFound> {
        let mine = homes.account(in: environment)
        guard let moved = UserHomes.given("UDECK_HOME", in: environment) else {
            guard let mine else {
                return .failure(HomeNotFound(description: "the account has no home folder to find ~/.udeck in"))
            }
            return .success(absolute(mine, from: here).appendingPathComponent(".udeck", isDirectory: true))
        }
        guard moved.utf8.first == UInt8(ascii: "~") else { return .success(absolute(moved, from: here)) }
        let bytes = Array(moved.utf8)
        let slash = bytes.firstIndex(of: UInt8(ascii: "/")) ?? bytes.count
        let user = String(decoding: bytes[1 ..< slash], as: UTF8.self)
        let rest = String(decoding: bytes[slash...], as: UTF8.self)
        if user.isEmpty {
            guard let mine else {
                return .failure(HomeNotFound(description: "UDECK_HOME is \(moved), and the account has no home folder for "
                                             + "its ~"))
            }
            return .success(absolute(mine + rest, from: here))
        }
        guard let theirs = homes.account(named: user, in: environment) else {
            return .failure(HomeNotFound(description: "UDECK_HOME is \(moved), and this machine has no account \(user) "
                                         + "for its ~\(user)"))
        }
        return .success(absolute(theirs + rest, from: here))
    }

    // MARK: - run

    static func runPlugin(_ arguments: [String], environment: [String: String], here: String, homes: UserHomes,
                          output: (String) -> Void, errors: (String) -> Void) async -> Int32 {
        let parsed: Parsed
        let reason: RefreshReason
        do {
            parsed = try parse(arguments, flags: [], values: ["--home", "--lang", "--reason"])
            guard parsed.operands.count == 1 else {
                throw UsageError(message: parsed.operands.isEmpty ? "run needs the plugin folder to run" : "run runs one plugin at a time")
            }
            let named = parsed.values["--reason"] ?? RefreshReason.interval.rawValue
            guard let known = RefreshReason(rawValue: named) else {
                throw UsageError(message: "--reason is one of \(RefreshReason.allCases.map(\.rawValue).joined(separator: ", ")), not \"\(named)\"")
            }
            reason = known
            if parsed.values["--home"]?.isEmpty == true { throw UsageError(message: emptyHome) }
            if let language = parsed.values["--lang"], language.isEmpty || !language.utf8.allSatisfy({
                (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains($0)
                    || $0 == UInt8(ascii: "-")
            }) {
                throw UsageError(message: "--lang is a language's code, like en or ru, not \"\(language)\"")
            }
        } catch let error as UsageError {
            errors("udeck-plugin run: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        #if canImport(Darwin)
        let folder = absolute(parsed.operands[0], from: here)
        let options = PluginTrial.Options(home: parsed.values["--home"].map { absolute($0, from: here) },
                                          language: parsed.values["--lang"] ?? "en", reason: reason,
                                          environment: environment, homes: homes)
        let report: PluginTrial.Report
        do {
            report = try await PluginTrial.run(folder, options: options)
        } catch let refusal as PluginTrial.Refusal {
            errors("udeck-plugin run: could not run \(shown(folder, from: here)): \(refusal.description)")
            return 2
        } catch {
            errors("udeck-plugin run: could not run \(shown(folder, from: here)): \(error)")
            return 2
        }
        return say(report, folder: shown(folder, from: here), output: output)
        #else
        _ = (reason, homes)
        errors("udeck-plugin run: runs a plugin the way uDeck runs it, which takes a Mac: uDeck and the plugins it "
               + "runs are macOS programs, and so is the code that runs them. check, check-repo and new work here")
        return 2
        #endif
    }

    #if canImport(Darwin)
    /// Prints what one run came to, and answers its exit status.
    static func say(_ report: PluginTrial.Report, folder: String, output: (String) -> Void) -> Int32 {
        let manifest = report.manifest
        let result = report.result
        output("ran \(folder) as uDeck runs it: \(manifest.id.rawValue) \(manifest.version), in its folder, with "
               + "uDeck's environment")
        output("home: \(report.home.path)" + (report.homeIsTemporary ? " (made for this run, and taken away after it)" : ""))
        output("UDECK_CACHE_DIR=\(report.environment["UDECK_CACHE_DIR"] ?? "")")
        output("UDECK_LANG=\(report.environment["UDECK_LANG"] ?? "") "
               + "UDECK_REFRESH_REASON=\(report.environment["UDECK_REFRESH_REASON"] ?? "") "
               + "PATH=\(report.environment["PATH"] ?? "")")
        let timeout = manifest.timeout.map { " of its \(Seconds.fixed($0, places: $0 == $0.rounded() ? 0 : 1)) s timeout" } ?? ""
        output("took \(Seconds.fixed(result.duration, places: 2)) s\(timeout)")
        output("ended: \(result.termination.summary)")
        output("stdout: \(bytes(result.standardOutput.count))\(dropped(result.standardOutputDropped))")
        if result.standardError.isEmpty {
            output(result.standardErrorDropped == 0 ? "stderr: nothing"
                                                    : "stderr: nothing kept\(droppedBefore(result.standardErrorDropped))")
        } else {
            let lines = String(decoding: result.standardError, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let shown = lines.last == "" ? lines.dropLast() : lines[...]
            output("stderr: \(bytes(result.standardError.count)), \(shown.count) line\(shown.count == 1 ? "" : "s")"
                   + "\(droppedBefore(result.standardErrorDropped)):")
            for line in shown { output("  | \(line)") }
        }
        let status: Int32
        switch report.execution {
        case .card(let card):
            output("uDeck draws the card:")
            for line in pretty(card) { output("  \(line)") }
            status = 0
        case .lateCard(let card, let failure):
            output("uDeck draws the card, and counts a failure: \(failure.reason)")
            for line in pretty(card) { output("  \(line)") }
            status = 1
        case .failure(let failure):
            output("uDeck shows a failure: \(failure.reason)")
            status = 1
        }
        for note in report.notes { output("note: \(note)") }
        for warning in report.warnings { output("warning: \(warning)") }
        let warnings = report.warnings.count
        output("ran \(folder): \(status == 0 ? "a card" : "a failure"), \(warnings) warning\(warnings == 1 ? "" : "s")")
        return status
    }

    static func bytes(_ count: Int) -> String {
        "\(count) byte\(count == 1 ? "" : "s")"
    }

    /// What of standard output went past the output limit, after what was
    /// kept of it.
    static func dropped(_ count: Int) -> String {
        count == 0 ? "" : " (and \(bytes(count)) past the output limit, dropped)"
    }

    /// What of standard error came before the tail uDeck keeps of it, after
    /// what was kept.
    static func droppedBefore(_ count: Int) -> String {
        count == 0 ? "" : " (its end: the \(bytes(count)) before it, dropped)"
    }

    /// The card as uDeck holds it, as indented JSON with its keys in order.
    static func pretty(_ card: Card) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(card) else { return ["(the card cannot be written as JSON)"] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    #endif

    /// `url` as the person asked for it: relative to `here` when it is inside
    /// it, absolute otherwise.
    static func shown(_ url: URL, from here: String) -> String {
        let base = URL(fileURLWithPath: here).standardizedFileURL.path
        let path = url.path
        let prefix = FilePaths.endsWithSeparator(base) ? base : base + "/"
        if path.utf8.starts(with: prefix.utf8), path.utf8.count > prefix.utf8.count {
            return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }
        return path
    }
}
