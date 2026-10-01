#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Rule 18: whenever anything in a plugin's folder changed, its `version` went
/// up — so "changed, but still 1.2.0" cannot reach a branch that is checked,
/// and a version names one content wherever it is installed from.
///
/// Which plugins changed is read against the merge base of `base` and `head`,
/// so a plugin changed only on the target branch is not this change's
/// business. The version is held to `base` itself, the target branch's tip:
/// when two pull requests both take `uptime` to 1.1.0, the second one to be
/// checked against the new tip has to go on to 1.1.1. A plugin that is new,
/// or whose version at `base` is not one to compare with, only needs a
/// version that parses, which rule 4 sees to.
///
/// The version is read the way uDeck reads it — `PluginManifest`, through
/// `JSONDecoder` — so a manifest the strict reader refuses and uDeck installs
/// (a byte order mark, `1e400` in a field nobody reads) is held to the rule
/// all the same. A manifest uDeck cannot read at all is rule 3's error already,
/// in every layer, and has no version to compare.
enum VersionBump {
    /// `label` is how the base is named to the author — `origin/main` — or nil
    /// when it is the commit before `head`.
    static func check(_ git: Git, base: String, head: String, label: String?, report: inout CheckReport) throws {
        guard let since = try git.mergeBase(base, head) else {
            // Without the point they branched at, every folder would look
            // changed: a shallow clone, or histories that never met.
            report.error(CheckRule.versionBump, "", "cannot compare with \(label ?? String(base.prefix(12))): no common "
                         + "history here — fetch full history (fetch-depth: 0)")
            return
        }
        let before = try folders(git, at: since)
        let after = try folders(git, at: head)
        // A folder whose name is no plugin id is rule 1's, and nothing uDeck
        // would install to compare versions of.
        let changed = after.filter { before[$0.key] != $0.value && PluginIdentifier(rawValue: $0.key) != nil }.keys.sorted()
        guard !changed.isEmpty else { return }

        // Read by blob id, from each commit's listing: git says "missing" alike
        // for a manifest a commit does not have, which is a plugin that is new
        // there, and for one a partial clone left out (`filter: blob:none`),
        // which is a version that cannot be compared — said, never passed.
        // What the clone does not hold is never asked for (`Git.absent`).
        let atBase = try manifests(git, at: base, of: changed)
        let atHead = try manifests(git, at: head, of: changed)
        let absent = try git.absent(at: [base, head], under: ["plugins/"])
        let blobs = try git.blobs((Array(atBase.values) + Array(atHead.values)).filter { !absent.contains($0) })
        func version(_ blob: String?) -> SemanticVersion? {
            guard let blob, let bytes = blobs[blob],
                  let decoded = try? JSONDecoder().decode(PluginManifest.self, from: Data(bytes)) else { return nil }
            return SemanticVersion(decoded.version)
        }
        let manifest = PluginDiscovery.manifestFilename
        let name = label.map { base.hasPrefix($0) ? String(base.prefix(12)) : "\($0) (\(base.prefix(12)))" }
            ?? "the commit before, \(base.prefix(12)),"
        for id in changed {
            let path = "plugins/\(id)/\(manifest)"
            if [atBase[id], atHead[id]].contains(where: { $0.map { blobs[$0] == nil } ?? false }) {
                report.error(CheckRule.versionBump, "", "cannot compare with \(label ?? "the commit before, \(base.prefix(12))"): "
                             + "\(path) is not in this clone — fetch without a blob filter")
                continue
            }
            guard let now = version(atHead[id]), let then = version(atBase[id]), now <= then else { continue }
            report.error(CheckRule.versionBump, path,
                         "the folder changed, and \"version\" is \(now) where \(name) has \(then); "
                         + "any change goes out as a new version — \(then.next) or later")
        }
    }

    /// Rule 18 for a push, which names no base: the commit before `head` is
    /// the base. A first commit has nothing before it to compare with; a
    /// commit whose parent a shallow clone left out has, and is said to be
    /// unchecked rather than passed.
    static func checkAgainstParent(_ git: Git, head: String, report: inout CheckReport) throws {
        if let parent = try git.commitIfAny(head + "^1") {
            try check(git, base: parent, head: head, label: nil, report: &report)
        } else if try git.parentsWritten(in: head) > 0 {
            report.warning(CheckRule.versionBump, "", "rule 18 not checked: HEAD has no parent here — fetch history "
                           + "(fetch-depth: 2 or 0)")
        }
    }

    /// The tree id of every folder directly under `plugins/` at `commit`.
    static func folders(_ git: Git, at commit: String) throws -> [String: String] {
        let output = try git.run(["ls-tree", "-z", commit, "--", "plugins/"])
        var folders: [String: String] = [:]
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard meta.count == 3, meta[1] == "tree", path.hasPrefix("plugins/") else { continue }
            folders[String(path.dropFirst("plugins/".count))] = String(meta[2])
        }
        return folders
    }

    /// The blob id of `plugins/<id>/manifest.json` at `commit`, for each of
    /// `ids` that has one there — from the commit's listing, which a clone
    /// without blobs still has whole.
    static func manifests(_ git: Git, at commit: String, of ids: [String]) throws -> [String: String] {
        let wanted = Set(ids)
        let output = try git.run(["ls-tree", "-r", "-z", commit, "--", "plugins/"])
        var manifests: [String: String] = [:]
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard meta.count == 3, meta[1] == "blob", parts.count == 3, parts[0] == "plugins",
                  parts[2] == PluginDiscovery.manifestFilename, wanted.contains(String(parts[1])) else { continue }
            manifests[String(parts[1])] = String(meta[2])
        }
        return manifests
    }
}
