import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Rules 14–17: what the official repository holds itself to on top of the
/// format, because "Verified" means a maintainer read the plugin before
/// merging it — so everything in it has to be readable, and everybody's rights
/// in it clear. Other repositories may hold whatever their owners choose.
enum OfficialRules {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let icon = "icon.png"
    static let screenshots = ["screenshot-1.png", "screenshot-2.png", "screenshot-3.png"]
    static let iconMaximumSide: UInt32 = 512
    static let screenshotMaximumBytes = 1024 * 1024

    /// The SHA-256 of the Apache License, Version 2.0, after `normalised` —
    /// the text of the official repository's own LICENSE. Pinned here rather
    /// than read from the repository, because a pull request can change that
    /// file too, and a check against a reference the change itself can edit
    /// checks nothing.
    static let apacheSHA256 = "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"

    // MARK: - Rule 14

    /// Every file is UTF-8 text, except an icon and up to three screenshots in PNG.
    static func textOnly(_ folder: String, entries: [TreeEntry], tree: Tree, report: inout CheckReport) {
        for entry in entries where entry.isFile {
            guard let content = tree.content(entry) else { continue } // larger than rule 8 allows
            let atTop = entry.path == folder + "/" + entry.name
            let pictureName = atTop && (entry.name == icon || screenshots.contains(entry.name))
            if content.starts(with: pngSignature) {
                guard pictureName else {
                    report.error("14", entry.path, "is a PNG; the only pictures a plugin may hold are icon.png and "
                                 + "screenshot-1.png ... screenshot-3.png, at the top of its folder")
                    continue
                }
                if entry.mode == TreeEntry.executable {
                    report.error("14", entry.path, "is a picture committed as executable; uDeck only ever shows a PNG -- "
                                 + "git update-index --chmod=-x \(entry.path)")
                }
                if let size = pngSize(content) {
                    if entry.name == icon, size.width > iconMaximumSide || size.height > iconMaximumSide {
                        report.error("14", entry.path, "is \(size.width)x\(size.height); an icon is at most "
                                     + "\(iconMaximumSide)x\(iconMaximumSide)")
                    }
                } else {
                    report.error("14", entry.path, "starts like a PNG but has no IHDR chunk; it is not a picture uDeck can show")
                }
                if screenshots.contains(entry.name), content.count > screenshotMaximumBytes {
                    report.error("14", entry.path, "is \(content.count) bytes; a screenshot is at most "
                                 + "\(screenshotMaximumBytes) (1 MiB)")
                }
                continue
            }
            if pictureName {
                report.error("14", entry.path, "is named like a picture but is not a PNG; a PNG is recognised by its "
                             + "signature, not its name")
                continue
            }
            if content.contains(0) {
                report.error("14", entry.path, "contains a NUL byte, so it is not text; a binary cannot be read by a "
                             + "reviewer, so it cannot be verified")
                continue
            }
            if let bad = StrictJSON.firstInvalidUTF8(content) {
                report.error("14", entry.path, "is not valid UTF-8 (byte \(bad)); every file in the official repository "
                             + "is UTF-8 text")
            }
        }
    }

    /// Width and height from a PNG's IHDR chunk, or nil when there is none
    /// where it must be.
    static func pngSize(_ content: [UInt8]) -> (width: UInt32, height: UInt32)? {
        guard content.count >= 24, Array(content[12 ..< 16]) == Array("IHDR".utf8) else { return nil }
        func number(_ start: Int) -> UInt32 { content[start ..< start + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        return (number(16), number(20))
    }

    // MARK: - Rule 15

    /// `author` is set. Answers the author, or nil — also when there is no
    /// manifest to read it from, or it is not text, which rule 3 has said.
    static func author(_ manifest: StrictJSON.Object?, folder: String, report: inout CheckReport) -> String? {
        guard let manifest else { return nil }
        let author = manifest.last("author")
        if let text = author?.string, !PythonSpace.isBlank(text) { return text }
        if let author, !author.isNull, author.string == nil { return nil }
        report.error("15", folder + "/" + PluginDiscovery.manifestFilename,
                     "\"author\" is not set; it is the name the copyright belongs to")
        return nil
    }

    // MARK: - Rule 16

    /// `Copyright <year> <author>`, a blank line, then the Apache License 2.0.
    static func licence(_ folder: String, entry: TreeEntry?, author: String?, tree: Tree, report: inout CheckReport) {
        let path = folder + "/LICENSE"
        guard let entry, entry.isFile else {
            report.error("16", path, "is missing; every plugin here is Apache-2.0, and its LICENSE says whose it is")
            return
        }
        guard let content = tree.content(entry), StrictJSON.firstInvalidUTF8(content) == nil else { return } // rule 14 says so
        let text = String(decoding: content, as: UTF8.self)
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        let first = String(PythonSpace.trimmingEnd(lines[0]))
        if let holder = copyrightHolder(first) {
            if let author, !holder.unicodeScalars.elementsEqual(author.unicodeScalars) {
                report.error("16", path, "says the copyright is \"\(holder)\", but the manifest's author is \"\(author)\"; "
                             + "they must be the same name")
            }
        } else {
            report.error("16", path, "must start with the line \"Copyright <year> <author>\", not \"\(first)\"")
        }
        let body: ArraySlice<Substring.UnicodeScalarView>
        if lines.count < 2 || !PythonSpace.isBlank(String(lines[1])) {
            report.error("16", path, "must have a blank line after the copyright line")
            body = lines.dropFirst(1)
        } else {
            body = lines.dropFirst(2)
        }
        if !isApache(Array(body)) {
            report.error("16", path, "after the copyright line and a blank line, must hold the unmodified text of the "
                         + "Apache License, Version 2.0 -- copy it from the LICENSE at the top of this repository")
        }
    }

    /// Whether `lines` are the Apache License 2.0, as `normalised` reads them.
    static func isApache(_ lines: [Substring.UnicodeScalarView]) -> Bool {
        let digest = SHA256.hash(data: Data(normalised(lines).utf8))
        return digest.map({ byte in String(byte, radix: 16).count == 1 ? "0\(String(byte, radix: 16))" : String(byte, radix: 16) })
            .joined() == apacheSHA256
    }

    /// Whether the file `content` is the Apache License 2.0 and nothing else
    /// — what the official repository's own LICENSE is, and what makes
    /// `udeck-plugin new` give a plugin made there a LICENSE of its own.
    static func isApache(_ content: [UInt8]) -> Bool {
        guard StrictJSON.firstInvalidUTF8(content) == nil else { return false }
        let text = String(decoding: content, as: UTF8.self)
        return isApache(Array(text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)))
    }

    /// `<holder>` from `Copyright <four digits> <holder>`, or nil.
    static func copyrightHolder(_ line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        let prefix = Array("Copyright ".unicodeScalars)
        guard scalars.count > prefix.count + 5, Array(scalars[..<prefix.count]) == prefix else { return nil }
        let year = scalars[prefix.count ..< prefix.count + 4]
        guard year.allSatisfy({ ("0" ... "9").contains($0) }), scalars[prefix.count + 4] == " " else { return nil }
        var holder = String.UnicodeScalarView()
        holder.append(contentsOf: scalars[(prefix.count + 5)...])
        return String(holder)
    }

    /// The licence with trailing spaces and the blank lines around it ignored:
    /// word for word and line for line, but not byte for byte — the copy on
    /// apache.org opens with a blank line and GitHub's does not, and both are
    /// the unmodified licence.
    static func normalised(_ lines: [Substring.UnicodeScalarView]) -> String {
        var lines = lines.map { String(PythonSpace.trimmingEnd($0)) }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rule 17

    /// Every commit after `base` up to `head` carries a `Signed-off-by:` line.
    static func signOffs(_ git: Git, base: String, head: String, report: inout CheckReport) throws {
        for (sha, message) in try git.commits(after: base, upTo: head) where !message.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false).contains(where: isSignOff) {
            let subject = Blank.isBlank(message) ? "(no message)" : String(Blank.trimmed(message).prefix { $0 != "\n" })
            report.error("17", "commit \(sha.prefix(12))", "\"\(subject)\" has no Signed-off-by line. Sign it off with "
                         + "git commit --amend -s, or git rebase --signoff \(base.prefix(12)) for several, and push again")
        }
    }

    /// Whether one line of a message is the trailer `git commit -s` writes:
    /// `Signed-off-by: Name <address>` — a name that ends in something other
    /// than a space, one space, an address in angle brackets with no space in
    /// it, and nothing after but spaces and tabs.
    static func isSignOff<Line: Collection<Unicode.Scalar>>(_ line: Line) -> Bool {
        let prefix = Array("Signed-off-by: ".unicodeScalars)
        guard line.starts(with: prefix) else { return false }
        var rest = Array(line.dropFirst(prefix.count))
        while let last = rest.last, last == " " || last == "\t" { rest.removeLast() }
        guard rest.last == ">", let open = rest.lastIndex(of: "<") else { return false }
        let address = rest[(open + 1) ..< (rest.count - 1)]
        let name = rest[..<open]
        func plain(_ scalar: Unicode.Scalar) -> Bool { scalar != "<" && scalar != ">" && !PythonSpace.contains(scalar) }
        guard !address.isEmpty, address.allSatisfy(plain), name.last == " " else { return false }
        let beforeSpace = name.dropLast()
        guard let end = beforeSpace.last, plain(end) else { return false }
        return beforeSpace.allSatisfy { $0 != "<" && $0 != ">" && $0 != "\n" }
    }
}
