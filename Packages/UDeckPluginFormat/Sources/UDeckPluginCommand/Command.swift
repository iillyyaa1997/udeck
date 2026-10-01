#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import UDeckPluginFormat

/// `udeck-plugin`: its arguments, what it prints, and how it exits.
///
/// Arguments are read here, by hand, rather than through
/// swift-argument-parser: five commands and a dozen options do not need a
/// dependency, and the binary a repository's CI downloads stays small.
///
/// Exit status, as the Python check had it: 0 when there are no errors
/// (warnings do not fail a check), 1 when there are, and 2 when nothing could
/// be checked — a repository that is not one, a git that is not there, or
/// arguments that make no sense. Two is never "checked and fine". The other
/// commands keep to the same three: `new` and `link` are 0 when done, 1 when
/// what they would make is in the way, 2 for a request that makes no sense;
/// `run` is 0 when uDeck would draw the card, 1 when it would show a failure,
/// and 2 when it would not run the plugin at all.
public enum Command {
    public static let usage = """
        usage: udeck-plugin check [--strict] <folder>...
               udeck-plugin check-repo [--repo <path>] [--strict] [--official] [--base <rev> --head <rev>]
               udeck-plugin new <id> [--name <name>] [--author <name>] [--description <text>]
               udeck-plugin run <folder> [--home <folder>] [--lang <code>] [--reason interval|manual|launch]
               udeck-plugin link <folder> [--home <folder>]
               udeck-plugin --version | --help

        Checks, makes, runs and links uDeck plugins, by the plugin contract and the
        plugin repository format (docs/plugin-api.md, docs/plugin-repository.md in
        uDeck).

          check         a plugin folder, or a link to one: through git, as
                        committed, when it is committed in a working copy; from
                        disk when it is not
          check-repo    a plugin repository, at one commit: --head, or HEAD

          (no flag)     what uDeck refuses to install: the passport, rules 1, 3-8,
                        and LFS pointers (9)
          --strict      also rules 2, 9 (archive attributes), 10-13 and 19
                        (minUDeck), and JSON read strictly
          --official    also the official repository's rules 14-16, and 17 (sign-offs)
                        with --base and --head; implies --strict
          --base <rev>  the target branch's tip, and --head <rev> the commit to
          --head <rev>  check: rule 18 (a changed plugin's version goes up), and
                        17 with --official. Without them, check-repo compares
                        versions with the commit before HEAD, and warns when the
                        clone does not have it.
          --repo <path> the repository (default: the current folder)

          new           a plugin that works and passes check --strict: in a plugin
                        repository (udeck-plugins.json here or above) as
                        plugins/<id>/, anywhere else as ./<id>/; with a LICENSE when
                        the repository's own is the Apache License 2.0. --author
                        defaults to git's user.name
          run           the plugin's producer, once, as uDeck runs it (a Mac's
                        command): its folder, uDeck's environment, its timeout and
                        process group, the 1 MiB limit; then the card as uDeck reads
                        it, how long it took, how it ended, all of its stderr, and
                        what uDeck would have forgiven without a word
          --home <folder>
                        uDeck's folder: for run, where UDECK_CACHE_DIR is
                        (<home>/cache/<id>) and the settings' values are read from
                        (<home>/plugin-settings.json) -- default, a new folder for
                        the run alone; for link, where the link goes
                        (<home>/plugins/<id>) -- default ~/.udeck
          --lang <code> UDECK_LANG for run (default: en)
          --reason <why>
                        UDECK_REFRESH_REASON for run (default: interval)
          link          the folder into uDeck as <home>/plugins/<id>, a link, while
                        you work on it: only for an id that is free, and never
                        touching installed.json. rm the link to undo it

        Exit status: 0 no errors (warnings do not fail), 1 errors, 2 could not check.
        new and link: 0 done, 1 in the way, 2 wrong request. run: 0 a card, 1 a
        failure, 2 not run.
        """

    /// Runs `udeck-plugin` with `arguments`, the program's own name left out.
    /// `new`, `run` and `link` read a relative path from `currentDirectory`,
    /// the process's own when nil; `check` and `check-repo` read theirs as
    /// the process does, and say them as given.
    public static func run(_ arguments: [String], environment: [String: String], currentDirectory: String? = nil,
                           output: (String) -> Void, errors: (String) -> Void) async -> Int32 {
        guard let command = arguments.first else {
            errors(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        let here = currentDirectory ?? FileManager.default.currentDirectoryPath
        switch command {
        case "--version", "-V", "version":
            output("udeck-plugin \(UDeckRelease.version)")
            return 0
        case "--help", "-h", "help":
            output(usage)
            return 0
        case "check":
            RepositoryCheck.sweepTemporaryFolder()
            return check(rest, environment: environment, output: output, errors: errors)
        case "check-repo":
            RepositoryCheck.sweepTemporaryFolder()
            return checkRepository(rest, environment: environment, output: output, errors: errors)
        case "new":
            return makePlugin(rest, environment: environment, here: here, output: output, errors: errors)
        case "run":
            RepositoryCheck.sweepTemporaryFolder()
            return await runPlugin(rest, environment: environment, here: here, output: output, errors: errors)
        case "link":
            return linkPlugin(rest, environment: environment, here: here, output: output, errors: errors)
        case "pin":
            errors("udeck-plugin \(command): not in this release")
            return 2
        default:
            errors("udeck-plugin: there is no command \"\(command)\"\n\n\(usage)")
            return 2
        }
    }

    /// `path`, read from `here` when it is relative.
    static func absolute(_ path: String, from here: String) -> URL {
        let full = path.hasPrefix("/") ? path : (here.hasSuffix("/") ? here : here + "/") + path
        return URL(fileURLWithPath: full).standardizedFileURL
    }

    /// Options and what is left, read from `arguments`: `--name value`,
    /// `--name=value`, a bare `--flag`, and `--` before operands that start
    /// with a dash.
    struct Parsed {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var operands: [String] = []
    }

    struct UsageError: Error {
        var message: String
    }

    static func parse(_ arguments: [String], flags: Set<String>, values: Set<String>) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                parsed.operands.append(argument)
                continue
            }
            if argument == "--" { optionsEnded = true; continue }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if flags.contains(name) {
                guard parts.count == 1 else { throw UsageError(message: "\(name) takes no value") }
                parsed.flags.insert(name)
            } else if values.contains(name) {
                let value: String
                if parts.count == 2 {
                    value = String(parts[1])
                } else {
                    guard index < arguments.count else { throw UsageError(message: "\(name) needs a value") }
                    value = arguments[index]
                    index += 1
                }
                guard parsed.values[name] == nil else { throw UsageError(message: "\(name) is given twice") }
                parsed.values[name] = value
            } else {
                throw UsageError(message: "there is no option \(name)")
            }
        }
        return parsed
    }

    static func mode(_ parsed: Parsed) -> CheckMode {
        CheckMode(strict: parsed.flags.contains("--strict"), official: parsed.flags.contains("--official"))
    }

    static func check(_ arguments: [String], environment: [String: String],
                      output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(arguments, flags: ["--strict"], values: [])
            guard !parsed.operands.isEmpty else { throw UsageError(message: "check needs a plugin folder") }
        } catch let error as UsageError {
            errors("udeck-plugin check: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        let options = RepositoryCheck.Options(mode: mode(parsed), environment: environment)
        var status: Int32 = 0
        for folder in parsed.operands {
            do {
                let report = try RepositoryCheck.folder(folder, options: options)
                let place = report.commit.map { "at \($0.prefix(12))" } ?? "on disk"
                let shown = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
                status = max(status, say(report, summary: "checked \(shown) \(place)", mode: options.mode, output: output))
            } catch {
                output("could not check \(folder): \(error)")
                status = 2
            }
        }
        return status
    }

    static func checkRepository(_ arguments: [String], environment: [String: String],
                                output: (String) -> Void, errors: (String) -> Void) -> Int32 {
        let parsed: Parsed
        do {
            parsed = try parse(arguments, flags: ["--strict", "--official"], values: ["--repo", "--base", "--head"])
            guard parsed.operands.isEmpty else {
                throw UsageError(message: "check-repo takes no operands; the repository is --repo <path>")
            }
            guard (parsed.values["--base"] == nil) == (parsed.values["--head"] == nil) else {
                throw UsageError(message: "--base and --head go together")
            }
            for name in ["--base", "--head"] where parsed.values[name]?.hasPrefix("-") == true {
                throw UsageError(message: "\(name) names a commit, and no commit starts with \"-\"")
            }
        } catch let error as UsageError {
            errors("udeck-plugin check-repo: \(error.message)\n\n\(usage)")
            return 2
        } catch {
            return 2
        }
        let options = RepositoryCheck.Options(mode: mode(parsed), base: parsed.values["--base"],
                                              head: parsed.values["--head"], environment: environment)
        do {
            let report = try RepositoryCheck.repository(parsed.values["--repo"] ?? ".", at: parsed.values["--head"] ?? "HEAD",
                                                        options: options)
            let folders = report.pluginFolders
            let summary = "checked \(folders) plugin folder\(folders == 1 ? "" : "s") at \(report.commit?.prefix(12) ?? "")"
            return say(report, summary: summary, mode: options.mode, output: output)
        } catch {
            output("could not check: \(error)")
            return 2
        }
    }

    /// Prints the findings and the line that sums them up, and answers the
    /// exit status they make.
    static func say(_ report: CheckReport, summary: String, mode: CheckMode, output: (String) -> Void) -> Int32 {
        for note in report.notes { output("note: \(note)") }
        for finding in report.findings { output(finding.description) }
        let errors = report.errors.count
        let warnings = report.warnings.count
        let how = mode.official ? " as the official repository" : mode.strict ? " strictly" : ""
        output("\(summary)\(how): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
        return errors > 0 ? 1 : 0
    }
}
