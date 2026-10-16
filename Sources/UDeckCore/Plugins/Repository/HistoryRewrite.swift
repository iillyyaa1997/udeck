import Foundation

/// Whether the head a branch or a pull request moved to continues the commit
/// a copy of it was installed at — or its history was rewritten: a push that
/// replaced what was there (a force push), a branch reset to an older commit,
/// or the commit that was installed no longer there at all. Decided here,
/// whole, where it is tested.
///
/// Asked only when the head of the line a copy came from moved and the copy's
/// folder is another there — something is offered — and only of the two
/// commits that matter: the one installed and the new head, of that line
/// (`Comparison`). Never of the default branch: a pull request merged by a
/// squash has, against `main`, a history that went another way too (measured
/// when stage 3 was designed: `b8bdbba...7403916`, diverged), and that is no
/// rewrite of anything.
public enum HistoryRewrite {
    /// What a comparison of the installed commit (base) with the new head says
    /// — true: rewritten; false: it continues; nil: nothing is known, since
    /// the comparison got no answer that says, and it is asked again at the
    /// next read.
    ///
    /// * `ahead` — the new head continues what is installed: an ordinary
    ///   offer. `identical` too: nothing was rewritten.
    /// * `behind` — the branch went back to a commit before the one installed;
    ///   `diverged` — the head went another way from a commit both have:
    ///   either is history rewritten.
    /// * `notFound` — the commit installed is no longer there, which is what a
    ///   rewrite leaves once it is cleaned up: rewritten.
    /// * The limit, no answer, a refusal, an answer that could not be read:
    ///   not known.
    public static func rewritten(_ answer: Result<Comparison, ProviderError>) -> Bool? {
        switch answer {
        case .success(let comparison):
            switch comparison.status {
            case .ahead, .identical: false
            case .behind, .diverged: true
            }
        case .failure(.notFound): true
        case .failure: nil
        }
    }
}

/// What was found of the head the line a copy came from moved to: whether it
/// continues the commit installed (`HistoryRewrite`). It holds only for those
/// two commits — `from` the one installed, `to` the head — and is asked again
/// once either is another, so a copy updated to the head, or a head that moved
/// again, never shows what was found of another pair.
public struct HeadHistory: Codable, Equatable, Sendable {
    /// The commit the copy was installed at when this was found.
    public var from: String
    /// The head it was compared with.
    public var to: String
    /// The head does not continue `from`.
    public var rewritten: Bool
    public var checkedAt: Date

    public init(from: String, to: String, rewritten: Bool, checkedAt: Date) {
        self.from = from
        self.to = to
        self.rewritten = rewritten
        self.checkedAt = InstalledPlugins.wholeSeconds(checkedAt)
    }

    /// Whether this is what was found of exactly `installed` and `head`.
    public func holds(installed: String, head: String) -> Bool {
        from == installed && to == head
    }
}
