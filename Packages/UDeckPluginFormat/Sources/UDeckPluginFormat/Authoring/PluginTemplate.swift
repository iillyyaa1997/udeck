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

/// A plugin that already works, made where its author will work on it:
/// `udeck-plugin new`.
///
/// The point is not to save typing — a manifest is a dozen lines. It is that
/// the first plugin somebody writes should *run*, and pass every rule a
/// repository's CI holds it to, before they change anything, so that when it
/// stops doing either they know which of their own edits did it.
///
/// Where it goes: inside a plugin repository — a folder at or above the
/// current one holds `udeck-plugins.json` — to `plugins/<id>/` at its top;
/// anywhere else to `<id>/` in the current folder. Never into uDeck's own
/// plugins folder: what is there is what uDeck runs, and a plugin under way is
/// linked there instead (`PluginLink`).
public enum PluginTemplate {
    public struct Request: Sendable {
        public var id: String
        public var name: String?
        public var author: String?
        public var description: String?
        /// Where the command was started.
        public var start: URL
        /// The command's environment: where git is, and git's configuration,
        /// for `user.name` when no author is given.
        public var environment: [String: String]

        public init(id: String, name: String? = nil, author: String? = nil, description: String? = nil,
                    start: URL, environment: [String: String]) {
            self.id = id
            self.name = name
            self.author = author
            self.description = description
            self.start = start
            self.environment = environment
        }
    }

    /// What was made.
    public struct Made: Sendable {
        public var folder: URL
        /// The files, in the order they are listed.
        public var files: [String]
        /// The repository's top, when the plugin was made in one.
        public var repository: URL?
        /// Worth knowing: why there is no LICENSE, for one.
        public var notes: [String]
    }

    /// Why nothing was made. `isUsage` when the request itself is wrong — an
    /// id that is not one — rather than the place it would go.
    public struct Refusal: Error, CustomStringConvertible {
        public var description: String
        public var isUsage: Bool
    }

    /// What `name` is when none is given: the id in words, `disk-space` as
    /// `Disk space`.
    static func name(from id: String) -> String {
        let words = id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).joined(separator: " ")
        guard let first = words.first else { return id }
        return first.uppercased() + words.dropFirst()
    }

    static let defaultDescription = "Says hello: where a plugin starts, before it shows anything of its own."
    static let defaultRussianDescription = "Здоровается: с этого плагин начинается, пока не показывает ничего своего."

    /// Makes the plugin `request` asks for.
    public static func make(_ request: Request) throws -> Made {
        guard let id = PluginIdentifier(rawValue: request.id) else {
            throw Refusal(description: "\"\(request.id)\" is not a plugin id: lowercase letters, digits, \".\", \"_\" "
                          + "and \"-\", 1 to 64 of them, starting with a letter or a digit", isUsage: true)
        }
        let repository = repositoryRoot(above: request.start)
        let folder = repository.map {
            $0.appendingPathComponent(CommitListing.pluginsFolder, isDirectory: true)
                .appendingPathComponent(id.rawValue, isDirectory: true)
        } ?? request.start.appendingPathComponent(id.rawValue, isDirectory: true)
        // Anything at all there — a folder, a file, a link, even one that
        // points nowhere — is somebody's, and nothing of it is touched.
        if (try? FileManager.default.attributesOfItem(atPath: folder.path)) != nil {
            throw Refusal(description: "\(folder.path) is already there; nothing was written. Pick another id, or "
                          + "move it out of the way first", isUsage: false)
        }

        let author = try author(request)
        var notes: [String] = []
        var licence: [UInt8]?
        if let repository {
            let root = repository.appendingPathComponent("LICENSE")
            if let content = try? Data(contentsOf: root), OfficialRules.isApache(Array(content)) {
                guard let author else {
                    throw Refusal(description: "this repository licenses every plugin under the Apache License 2.0, and "
                                  + "a plugin's LICENSE says whose it is: say who you are with --author \"Your Name\", "
                                  + "or set git's user.name", isUsage: true)
                }
                licence = Array("Copyright \(year()) \(author)\n\n".utf8) + Array(content)
            } else {
                notes.append("no LICENSE: \(root.path) is not the Apache License 2.0, so how the plugin is licensed is "
                             + "yours to say. The official repository wants Apache-2.0 -- its CONTRIBUTING.md says how")
            }
        } else {
            notes.append("no LICENSE: \(request.start.path) is not in a plugin repository (no udeck-plugins.json in it "
                         + "or above it). Made inside one whose LICENSE is the Apache License 2.0, a plugin gets one")
        }

        let name = request.name.map(Blank.trimmed) ?? name(from: id.rawValue)
        guard !name.isEmpty else { throw Refusal(description: "--name is blank", isUsage: true) }
        let description = request.description.map(Blank.trimmed)
        let producer = "\(id.rawValue).sh"
        var files: [(name: String, content: [UInt8], executable: Bool)] = [
            ("manifest.json", Array(manifest(id: id.rawValue, name: name, description: description ?? defaultDescription,
                                             author: author, producer: producer).utf8), false),
            ("manifest.ru.json", Array(translation(name: name, description: description == nil
                                                      ? defaultRussianDescription : nil).utf8), false),
            ("README.md", Array(readme(name: name, description: description ?? defaultDescription, producer: producer,
                                       author: licence == nil ? nil : author).utf8), false),
            (producer, Array(script(name: name).utf8), true),
        ]
        if let licence { files.append(("LICENSE", licence, false)) }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let url = folder.appendingPathComponent(file.name)
                try Data(file.content).write(to: url)
                try manager.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
        } catch {
            throw Refusal(description: "could not write \(folder.path): \(error)", isUsage: false)
        }
        return Made(folder: folder, files: files.map(\.name), repository: repository, notes: notes)
    }

    /// The top of the plugin repository `folder` is in: the nearest folder,
    /// it or one above it, that holds `udeck-plugins.json`.
    static func repositoryRoot(above folder: URL) -> URL? {
        var current = folder.standardizedFileURL
        while true {
            let passport = current.appendingPathComponent(RepositoryPassport.path)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: passport.path),
               attributes[.type] as? FileAttributeType == .typeRegular {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// The author: `--author`, else git's `user.name` where the plugin is made.
    static func author(_ request: Request) throws -> String? {
        let author: String?
        if let given = request.author {
            author = Blank.trimmed(given)
            guard author?.isEmpty == false else { throw Refusal(description: "--author is blank", isUsage: true) }
        } else {
            let asked = try? Subprocess.run(["git", "-C", request.start.path, "config", "--get", "user.name"],
                                            environment: request.environment)
            let said = asked.flatMap { $0.status == 0 ? Blank.trimmed(String(decoding: $0.output, as: UTF8.self)) : nil }
            author = said?.isEmpty == false ? said : nil
        }
        if let author, author.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            throw Refusal(description: "the author is one line of text, with no line break or other control character in it",
                          isUsage: true)
        }
        return author
    }

    /// This year, where the command runs.
    static func year() -> Int {
        var now = time(nil)
        var parts = tm()
        guard localtime_r(&now, &parts) != nil else { return 1970 + Int(now / 31_556_952) }
        return Int(parts.tm_year) + 1900
    }

    // MARK: - The files

    static func manifest(id: String, name: String, description: String, author: String?, producer: String) -> String {
        var fields = [
            ("id", json(id)), ("name", json(name)), ("version", json("1.0.0")), ("api", "\(PluginAPI.current)"),
            ("kind", json("poll")), ("description", json(description)),
        ]
        if let author { fields.append(("author", json(author))) }
        fields += [("run", "[\(json("./" + producer))]"), ("interval", "60"), ("timeout", "2")]
        return "{\n" + fields.map { "  \(json($0.0)): \($0.1)" }.joined(separator: ",\n") + "\n}\n"
    }

    static func translation(name: String, description: String?) -> String {
        var fields = [("name", json(name))]
        if let description { fields.append(("description", json(description))) }
        return "{\n" + fields.map { "  \(json($0.0)): \($0.1)" }.joined(separator: ",\n") + "\n}\n"
    }

    static func readme(name: String, description: String, producer: String, author: String?) -> String {
        var text = """
            # \(name)

            \(description)

            ## What the card shows

            A greeting, in the panel's language — English or Russian, from
            `UDECK_LANG` — and why uDeck ran the plugin this time
            (`UDECK_REFRESH_REASON`). It is where the plugin starts: replace it with
            what the card is for, and say here what each row means.

            ## What it needs and what it runs

            Nothing to install. `\(producer)` is POSIX `sh`, and it runs `tr` and
            `sed` on its own text, both of which every Mac has. It reads no file,
            writes none — not even in its own folder, which has to stay exactly what
            the repository holds — and reaches nothing over the network.

            ## Permissions

            None: it reads, runs and reaches nothing a plugin has to ask the operator
            for. When it starts to, declare it under `permissions` in `manifest.json`
            and say so here.

            ## Settings

            None.

            """
        if let author {
            text += """

                ## Licence

                Apache-2.0, copyright \(author) — see [LICENSE](LICENSE).

                """
        }
        return text
    }

    static func script(name: String) -> String {
        """
        #!/bin/sh
        # \(name): a uDeck producer. It prints one card, as JSON, on standard
        # output, and exits 0; anything else it has to say goes to standard error.
        #
        # Run it the way uDeck does, and see what uDeck makes of it:
        #
        #     udeck-plugin run <this folder>
        #
        # Every field of a card, and every variable uDeck hands a producer, is in
        # the plugin contract: docs/plugin-api.md in uDeck.

        # Text made safe inside a JSON string: tabs and line breaks made spaces,
        # other control characters dropped, backslashes and quotes escaped. Build
        # the card with this, never by pasting a value into the JSON as it is: one
        # quote in a value makes a card uDeck cannot read.
        json_string() {
            printf '"%s"' "$(printf '%s' "$1" | tr '\\t\\r\\n' '   ' | tr -d '\\001-\\037' | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')"
        }

        # UDECK_LANG is the language the panel speaks: answer in it if you can.
        case "${UDECK_LANG:-en}" in
            ru)
                greeting="Привет! Здесь будет то, что показывает плагин."
                reason="причина запуска"
                ;;
            *)
                greeting="Hello! This is where the plugin shows what it found."
                reason="refreshed because"
                ;;
        esac

        # ttl: how long the card can be trusted — about four intervals. Past it
        # uDeck dims the card; past three times it, hides the values.
        printf '{"state": "ok", "rows": [{"text": %s}, {"kv": [%s, %s]}], "ttl": 240}\\n' \\
            "$(json_string "$greeting")" \\
            "$(json_string "$reason")" \\
            "$(json_string "${UDECK_REFRESH_REASON:-}")"

        """
    }

    /// `text` as a JSON string: quotes, backslashes and control characters
    /// escaped, everything else as it is.
    static func json(_ text: String) -> String {
        var escaped = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                escaped += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}
