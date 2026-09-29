import Foundation

/// Which plugins are quiet — being replaced or removed — and how many runs of
/// each are in flight, polls and card actions alike.
///
/// A plugin is quieted before its folder is swapped or taken away, so that no
/// run starts in one version's folder and reads the other's. Every run asks
/// `begin` first, and a quiet plugin is told no; whoever quiets it waits until
/// `isRunning` says the runs that had started are over.
public struct PluginQuiet: Equatable, Sendable {
    private var quieted: Set<String> = []
    private var inFlight: [String: Int] = [:]

    public init() {}

    /// Nothing more of `id` starts until `resume`.
    public mutating func quiet(_ id: String) {
        quieted.insert(id)
    }

    public mutating func resume(_ id: String) {
        quieted.remove(id)
    }

    public func isQuiet(_ id: String) -> Bool {
        quieted.contains(id)
    }

    /// A run of `id` is about to start. False, and nothing counted, when the
    /// plugin is quiet: the run must not start. True, and it is counted until
    /// `end`.
    public mutating func begin(_ id: String) -> Bool {
        guard !quieted.contains(id) else { return false }
        inFlight[id, default: 0] += 1
        return true
    }

    /// A run that `begin` let start is over.
    public mutating func end(_ id: String) {
        guard let count = inFlight[id] else { return }
        inFlight[id] = count > 1 ? count - 1 : nil
    }

    /// Whether any run of `id` is still in flight.
    public func isRunning(_ id: String) -> Bool {
        (inFlight[id] ?? 0) > 0
    }
}
