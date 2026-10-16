import Foundation

/// Why **Install from a link…** lists nothing to install, as Settings says it
/// — each refusal naming what the link was, why it is not read, and what to
/// paste instead — decided here, where the sentences are tested.
public enum LinkRefusal {
    /// What Settings says of `error`, thrown reading a pasted link
    /// (`RepositoryLink.Refusal`) or asking GitHub about it
    /// (`RefResolver.Refusal`), `official` being the official repository —
    /// nil for any other error: a request that got no answer, the limit, a
    /// listing that could not be read, which Settings says the way it says
    /// every such problem.
    public static func phrase(_ error: any Error, official: RepositoryAddress) -> Phrase? {
        switch error {
        case let refusal as RepositoryLink.Refusal:
            .linkRefused(refusal, official: official.description)
        case RefResolver.Refusal.notFound(let link):
            .linkNotFound(link, official: official.description)
        case RefResolver.Refusal.notAFork(let address):
            .linkNotAFork(repository: address.description, official: official.description)
        default:
            nil
        }
    }

    /// What a resolved link says above its list: the line of history and the
    /// commit it was read at (`linkHead`), whether a pull request was merged —
    /// into the default branch, whose merge is what the catalogue has, or into
    /// another, where nothing of it is verified — or closed, and — when nothing
    /// there differs from the catalogue's head — that there is nothing to
    /// install from it: of every plugin there, or of the one plugin a link
    /// into its folder named, which may not be there at all. A merge into a
    /// branch GitHub did not name, or while the default branch is not known,
    /// is said as a merge. A fork's branch is named with its fork, every time.
    public static func head(of resolution: RefResolver.Resolution) -> [Phrase] {
        let fork = resolution.fork
        var said: [Phrase] = [.linkHead(ref: resolution.origin.ref, commit: String(resolution.commit.prefix(7)), fork: fork)]
        if let pull = resolution.pullRequest {
            if pull.merged, let base = pull.base, let defaultBranch = resolution.defaultBranch, base != defaultBranch {
                said.append(.linkPullRequestMergedElsewhere(base: base))
            } else if pull.merged {
                said.append(.linkPullRequestMerged)
            } else if pull.state == .closed {
                said.append(.linkPullRequestClosed)
            }
        }
        if resolution.entries.isEmpty {
            let ref = resolution.origin.ref
            if let plugin = resolution.plugin, resolution.listing.plugins[plugin] == nil {
                said.append(.linkPluginNotThere(ref: ref, plugin: plugin, fork: fork))
            } else {
                said.append(.linkNothingDiffers(ref: ref, plugin: resolution.plugin, fork: fork))
            }
        }
        return said
    }
}
