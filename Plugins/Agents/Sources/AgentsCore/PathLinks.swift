import Foundation

/// Paths to files in an answer made links the feed draws in blue (uDeck
/// 0.9.27; the operator's «1» to question 205, 11-27): a click opens the file
/// in the editor at its line, ⌘ shows it in Finder, ⌥ in Quick Look.
///
/// Only what exists: a path the answer names, as it is, from the session's
/// folder or the home folder — «a/b» that is no file stays text. Fenced code
/// and links already written are left as they are. A finished answer is
/// linked once and kept: the card is drawn five times a second.
@MainActor
enum PathLinks {
    private static var made: [String: String] = [:]

    /// The answer with its paths as `file:` links, `#L<line>` for a line.
    static func link(_ text: String, folder: URL) -> String {
        let key = folder.path + "\u{1}" + text
        if let done = made[key] { return done }
        let linked = linkNow(text, folder: folder)
        if made.count > 400 { made.removeAll() }
        made[key] = linked
        return linked
    }

    nonisolated static func linkNow(_ text: String, folder: URL) -> String {
        var out: [String] = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                out.append(line)
                continue
            }
            out.append(fenced ? line : linkLine(line, folder: folder))
        }
        return out.joined(separator: "\n")
    }

    /// A line's paths linked: tokens between spaces, or in backticks.
    nonisolated static func linkLine(_ line: String, folder: URL) -> String {
        guard line.contains("/") || line.contains(".") else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            // A link already written: as it is, up to its closing bracket.
            if character == "[", let close = line[index...].range(of: "](") {
                if let end = line[close.upperBound...].firstIndex(of: ")") {
                    result += line[index...end]
                    index = line.index(after: end)
                    continue
                }
            }
            if character == "`", let end = line[line.index(after: index)...].firstIndex(of: "`") {
                let inside = String(line[line.index(after: index)..<end])
                if let url = fileURL(inside, folder: folder) {
                    result += "[`" + inside + "`](" + url + ")"
                } else {
                    result += line[index...end]
                }
                index = line.index(after: end)
                continue
            }
            if character.isWhitespace {
                result.append(character)
                index = line.index(after: index)
                continue
            }
            // A word: up to the next space or backtick.
            var end = index
            while end < line.endIndex, !line[end].isWhitespace, line[end] != "`" { end = line.index(after: end) }
            let word = String(line[index..<end])
            result += linkWord(word, folder: folder)
            index = end
        }
        return result
    }

    /// A word with what surrounds a path — brackets, quotes, a full stop —
    /// kept outside the link.
    nonisolated static func linkWord(_ word: String, folder: URL) -> String {
        let opening = CharacterSet(charactersIn: "([{«\"'“")
        let closing = CharacterSet(charactersIn: ")]}»\"'”.,;!?")
        var core = Substring(word)
        var before = ""
        var after = ""
        while let first = core.unicodeScalars.first, opening.contains(first) {
            before.append(core.removeFirst())
        }
        while let last = core.unicodeScalars.last, closing.contains(last) {
            after = String(core.removeLast()) + after
        }
        // «path:12:» — a colon after the line is the sentence's.
        if core.hasSuffix(":") { core.removeLast(); after = ":" + after }
        guard !core.isEmpty, let url = fileURL(String(core), folder: folder) else { return word }
        return before + "[" + core + "](" + url + ")" + after
    }

    /// The `file:` link for a path that exists, with its line — `path:154`,
    /// `path:154:3` — as `#L154`.
    nonisolated static func fileURL(_ token: String, folder: URL) -> String? {
        guard token.count > 2, !token.contains("://"), token.contains("/") || token.contains(".") else { return nil }
        var path = token
        var line: Int?
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let number = Int(parts[1]), number > 0 {
            path = String(parts[0])
            line = number
        }
        guard !path.isEmpty, path.rangeOfCharacter(from: .letters) != nil else { return nil }
        let full: URL
        if path.hasPrefix("/") {
            full = URL(fileURLWithPath: path)
        } else if path.hasPrefix("~/") {
            full = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        } else {
            // A bare name with no folder is a file only in the session's own.
            full = folder.appendingPathComponent(path)
        }
        guard FileManager.default.fileExists(atPath: full.path) else { return nil }
        // Spaces and the like, written so the link survives Markdown.
        var link = URL(fileURLWithPath: full.standardizedFileURL.path).absoluteString
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        if let line { link += "#L\(line)" }
        return link
    }
}
