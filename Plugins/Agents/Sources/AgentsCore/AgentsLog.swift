import Foundation

/// What this plugin decided as it started and stopped — what a place kept,
/// what came back, what was held back or stopped — in
/// `~/.udeck/agents/agents.log`, a quarter of a megabyte at most. 11-27 the
/// sessions «reset» after an update twice, and nothing said why.
public struct AgentsLog: Sendable {
    let file: URL
    static let most = 256 * 1024

    public init(home: URL) {
        file = home.appendingPathComponent(".udeck/agents/agents.log")
    }

    public func say(_ text: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > Self.most,
           let data = try? Data(contentsOf: file) {
            // The newer half is kept.
            try? data.suffix(Self.most / 2).write(to: file, options: .atomic)
        }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}
