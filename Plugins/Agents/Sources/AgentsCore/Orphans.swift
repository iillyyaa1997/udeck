import Foundation

/// A `claude` this plugin started in a run before, still going after that run
/// died: a resumed session's process whose parent is gone (launchd's now).
/// 11-27 uDeck 0.9.21 stopped the old Agents, its `claude --resume 46c04e…`
/// lived on, and the new Agents found the session «running elsewhere» — two
/// processes writing one transcript once it was continued here.
public enum Orphans {
    /// Process ids of the orphans resuming `sessionID` with this plugin's
    /// stream-json flags, in `ps -ax -o pid=,ppid=,command=` output.
    public static func resuming(_ sessionID: String, in listing: String) -> [Int32] {
        listing.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] == "1" else { return nil }
            let command = fields[2]
            guard command.contains("--input-format stream-json"), command.contains("--resume " + sessionID)
            else { return nil }
            return pid
        }
    }

    /// Stops the orphans resuming `sessionID`: SIGTERM, then SIGKILL for one
    /// still there two seconds later.
    public static func stop(resuming sessionID: String) async {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let found = resuming(sessionID, in: String(decoding: data, as: UTF8.self))
        guard !found.isEmpty else { return }
        for pid in found { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(2))
        for pid in found where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
