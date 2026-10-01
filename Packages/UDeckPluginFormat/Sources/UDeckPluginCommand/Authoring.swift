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

    static func linkPlugin(_ arguments: [String], environment: [String: String], here: String,
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
        let home: URL
        if let given = parsed.values["--home"] {
            home = absolute(given, from: here)
        } else if let user = environment["HOME"], !user.isEmpty {
            home = URL(fileURLWithPath: user).appendingPathComponent(".udeck", isDirectory: true)
        } else {
            errors("udeck-plugin link: there is no HOME to find ~/.udeck in; say where uDeck's folder is with --home")
            return 2
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
        output("to undo it: rm \(linked.link.path) (the link goes; the folder it points at stays as it is)")
        if !PluginLink.udeckReadsLinks {
            output("note: this uDeck does not list a plugin through a link yet: it skips a link in its plugins folder, "
                   + "and lists the plugin once a release that reads links is installed")
        }
        return 0
    }

    // MARK: - run

    static func runPlugin(_ arguments: [String], environment: [String: String], here: String,
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
                                          environment: environment)
        let report: PluginTrial.Report
        do {
            report = try await PluginTrial.run(folder, options: options)
        } catch let refusal as PluginTrial.Refusal {
            output("could not run \(shown(folder, from: here)): \(refusal.description)")
            return 2
        } catch {
            output("could not run \(shown(folder, from: here)): \(error)")
            return 2
        }
        return say(report, folder: shown(folder, from: here), output: output)
        #else
        _ = reason
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
        output("ended: \(ending(result.termination))")
        output("stdout: \(result.standardOutput.count) byte\(result.standardOutput.count == 1 ? "" : "s")")
        if result.standardError.isEmpty {
            output("stderr: nothing")
        } else {
            let lines = String(decoding: result.standardError, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let shown = lines.last == "" ? lines.dropLast() : lines[...]
            output("stderr: \(result.standardError.count) byte\(result.standardError.count == 1 ? "" : "s"), "
                   + "\(shown.count) line\(shown.count == 1 ? "" : "s"):")
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

    /// How a run ended, in a line.
    static func ending(_ termination: Termination) -> String {
        switch termination {
        case .exited(let code): "exit status \(code)"
        case .signalled(let signal): "killed by signal \(signal)"
        case .timedOut(let seconds): "stopped by uDeck after \(Seconds.fixed(seconds, places: seconds == seconds.rounded() ? 0 : 1)) s, its timeout"
        case .outputLimitExceeded(let bytes): "stopped by uDeck after \(bytes) bytes of output, past its limit"
        case .launchFailed(let detail): "never started: \(detail)"
        }
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
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.utf8.starts(with: prefix.utf8), path.utf8.count > prefix.utf8.count {
            return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }
        return path
    }
}
