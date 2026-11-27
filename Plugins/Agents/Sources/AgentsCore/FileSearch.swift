import Foundation

/// The files of a session's folder, for «@» in the field: git's list where
/// the folder is a repository — what is ignored left out — else a walk that
/// stops at what a person never means (`.git`, `node_modules`, builds). Kept
/// a minute per folder.
actor FileSearch {
    static let shared = FileSearch()

    private var listed: [String: (at: Date, files: [String])] = [:]
    /// No folder gives more than this many files to search.
    static let most = 50_000

    /// The best of a folder's files for a query, as paths relative to it.
    func find(_ query: String, in folder: URL, limit: Int = 30) async -> [String] {
        let files = await files(in: folder)
        return Self.rank(files, query: query, limit: limit)
    }

    private func files(in folder: URL) async -> [String] {
        let key = folder.standardizedFileURL.path
        if let kept = listed[key], Date().timeIntervalSince(kept.at) < 60 { return kept.files }
        let files = await Task.detached { Self.git(folder) ?? Self.walk(folder) }.value
        listed[key] = (Date(), files)
        return files
    }

    /// `git ls-files`: tracked and untracked, ignored ones out.
    nonisolated static func git(_ folder: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "ls-files", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(most).map(String.init)
    }

    nonisolated static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv",
                                                   "venv", "__pycache__", ".next", "dist", "target", ".worktrees"]

    nonisolated static func walk(_ folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
            if files.count >= most { break }
        }
        return files
    }

    /// Best first: a file's name that starts with the query, then a name
    /// that has it, then a path that has it, then a path that has its letters
    /// in order; shorter paths first among equals.
    nonisolated static func rank(_ files: [String], query: String, limit: Int) -> [String] {
        let wanted = query.lowercased()
        guard !wanted.isEmpty else { return Array(files.sorted { $0.count < $1.count }.prefix(limit)) }
        var scored: [(Int, Int, String)] = []
        for file in files {
            let path = file.lowercased()
            let name = (path as NSString).lastPathComponent
            let score: Int
            if name.hasPrefix(wanted) { score = 0 }
            else if name.contains(wanted) { score = 1 }
            else if path.contains(wanted) { score = 2 }
            else if inOrder(wanted, path) { score = 3 }
            else { continue }
            scored.append((score, file.count, file))
        }
        return scored.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.prefix(limit).map(\.2)
    }

    nonisolated static func inOrder(_ letters: String, _ text: String) -> Bool {
        var rest = Substring(text)
        for letter in letters {
            guard let at = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        return true
    }
}
