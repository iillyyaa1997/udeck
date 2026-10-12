import Foundation

// What uDeck says of a copy installed from a branch or a pull request — code
// nobody verified — wherever it shows one: the row in Settings, the catalogue
// row of the same id, the card's header and its question, and a warning
// before one copy takes the place of a copy from somewhere else. Each said in
// one place, here, where it is tested; the views only show it.

/// A copy of a plugin as a sentence names it — where it came from, and which
/// one: *the verified 1.1.0 from github.com/…*, *1.0.1 from pull request #3 at
/// a1b2c3d*, *1.0.1 from branch fix/uptime at a1b2c3d*. What a warning that
/// puts a copy from one line of history in the place of a copy from another
/// says of each (`ShownPlace.Switch`): both sources and the ref, before
/// anything is replaced.
public enum CopyName: Equatable, Sendable {
    /// From the source's default branch, whose copies are verified.
    case verified(version: String, repository: String)
    /// From pull request `number`, at `commit` — its first seven characters.
    case pullRequest(number: Int, commit: String, version: String)
    /// From branch `name`, at `commit`.
    case branch(name: String, commit: String, version: String)
    /// From a line of history this uDeck does not know, at `commit`.
    case other(commit: String, version: String)

    /// `version` at `commit`, from `origin`.
    public static func of(_ origin: PluginOrigin, commit: String, version: String) -> CopyName {
        let short = String(commit.prefix(7))
        if origin.ref.isDefault { return .verified(version: version, repository: origin.repository.description) }
        if let number = origin.ref.pullRequestNumber { return .pullRequest(number: number, commit: short, version: version) }
        if origin.ref.kind == PluginRef.branchKind, let name = origin.ref.name {
            return .branch(name: name, commit: short, version: version)
        }
        return .other(commit: short, version: version)
    }

    /// The same name, byte for byte: two spellings of a branch are two branches.
    static func same(_ one: CopyName, _ other: CopyName) -> Bool {
        switch (one, other) {
        case (.verified(let v1, let r1), .verified(let v2, let r2)):
            ShownPlace.same(v1, v2) && ShownPlace.same(r1, r2)
        case (.pullRequest(let n1, let c1, let v1), .pullRequest(let n2, let c2, let v2)):
            n1 == n2 && ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2)
        case (.branch(let b1, let c1, let v1), .branch(let b2, let c2, let v2)):
            ShownPlace.same(b1, b2) && ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2)
        case (.other(let c1, let v1), .other(let c2, let v2)):
            ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2)
        default:
            false
        }
    }
}

extension PluginOrigin {
    /// Whether a copy from `other` follows the same line of history as a copy
    /// from here: the source's default branch — whatever its repository is
    /// called now, a rename is no other source — or the same branch, or the
    /// same pull request, of the same repository, its name byte for byte.
    /// A copy from another line taking a copy's place is a switch of source,
    /// and its warning names both (`ShownPlace.Switch`).
    public func followsTheSameLine(as other: PluginOrigin) -> Bool {
        if ref.isDefault || other.ref.isDefault { return ref.isDefault && other.ref.isDefault }
        return repository == other.repository && ref.kind == other.ref.kind
            && ShownPlace.same(ref.name, other.ref.name)
    }
}

extension RepositoryAddress {
    /// Where a person reads `ref` of this repository in a browser: a pull
    /// request's page, or a branch's; nil for the default branch — the
    /// catalogue's own links read it — and for a kind this uDeck does not know.
    public func page(of ref: PluginRef) -> URL? {
        let base = "https://\(host)/\(path)"
        if let number = ref.pullRequestNumber { return URL(string: "\(base)/pull/\(number)") }
        guard ref.kind == PluginRef.branchKind, let name = ref.name, !name.isEmpty,
              let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(base)/tree/\(escaped)")
    }
}

extension InstalledRecord {
    /// Where the copy came from, as its row in Settings says it beside its
    /// mark: *From github.com/… at 5c3e0d2* for the source's default branch;
    /// *pull request #3 at a1b2c3d* or *branch fix/uptime at a1b2c3d* for
    /// code nobody verified, after **Unverified**.
    public var fromPhrase: Phrase {
        let commit = String(self.commit.prefix(7))
        if let number = ref.pullRequestNumber {
            return .pluginFromPullRequest(number: number, commit: commit)
        }
        if ref.kind == PluginRef.branchKind, let name = ref.name {
            return .pluginFromBranch(name: name, commit: commit)
        }
        return .pluginFrom(source: repository.description, commit: commit)
    }

    /// The page of the branch or the pull request the copy came from —
    /// nil for the default branch's.
    public var refPage: URL? { repository.page(of: ref) }

    /// What a window of this copy says beside **Reinstall** once its folder
    /// has gone: which copy **Reinstall** puts back, and from where, when that
    /// is code nobody verified — *Reinstall puts back 1.0.1 from pull request
    /// #3 at a1b2c3d: code nobody verified* — so that the button does not put a
    /// pull request's code back unsaid. Nil for the default branch's copy, and
    /// for a copy whose tree is the one the catalogue's head has
    /// (`headTree`): that is what was merged, and it comes back **Verified**
    /// (`Adoption`).
    public func reinstallSays(headTree: String?) -> Phrase? {
        guard !isOfficialDefault, tree != headTree else { return nil }
        return .windowReinstallBrings(CopyName.of(origin, commit: commit, version: version))
    }
}

extension UpdateOffer {
    /// What a row offers for an installed copy against the catalogue's head
    /// `entry`: `UpdateOffer.of` for a copy of the default branch — and
    /// nothing for code nobody verified. A branch's or a pull request's copy
    /// is not an older or a changed version of the catalogue's: the verified
    /// copy is offered as the switch it is (`CatalogueRowState.unverified`),
    /// never as an update, so nothing waits, and nothing updates by itself.
    public static func offered(_ record: InstalledRecord, head entry: CatalogueEntry?) -> UpdateOffer? {
        guard record.isOfficialDefault else { return nil }
        return of(record, head: entry)
    }
}

extension CatalogueRowState {
    /// What the catalogue row of an id installed from a branch or a pull
    /// request says under its name, in order: where the copy here came from,
    /// unverified (*Installed here from pull request #3: unverified*); what
    /// became of that pull request, when it was merged as something else or
    /// closed (`lifecycle`); that its folder is not in `path`, when it is
    /// gone; and why the verified copy cannot be installed here, when it
    /// cannot. Nil for every other state.
    public func unverifiedLine(ref: PluginRef, id: String, path: String,
                               lifecycle: PullRequestLifecycle? = nil) -> [Phrase]? {
        guard case .unverified(_, let refusal, let folderGone) = self else { return nil }
        return [.catalogueInstalledUnverified(ref: ref)]
            + (lifecycle?.cataloguePhrase.map { [$0] } ?? [])
            + (folderGone ? [.catalogueMissing(id: id, path: path)] : [])
            + (refusal.map { [.catalogueRefusal($0)] } ?? [])
    }
}

extension PluginStanding {
    /// Whether a window of the plugin says **Unverified** in its header: a
    /// branch's or a pull request's copy, exactly as installed or changed
    /// since — code nobody verified either way. A verified copy, a copy of
    /// the default branch changed on disk, a folder of the operator's own and
    /// a linked one say nothing there: their marks are Settings'.
    public static func cardSaysUnverified(_ standing: PluginStanding?, record: InstalledRecord?, linked: Bool) -> Bool {
        guard !linked else { return false }
        switch standing {
        case .unverified?: return true
        case .modifiedLocally?: return record.map { !$0.isOfficialDefault } ?? false
        default: return false
        }
    }
}

/// What the consent card says of where the code it asks about comes from —
/// for a decision held to its tree (`ConsentBasis`), which is code nobody
/// verified: *Nobody verified this code: it comes from pull request #3 of
/// github.com/…, not from what the repository merged.* Nothing for a decision
/// held to the version: a verified copy, a folder of the operator's own, a
/// link.
public enum ConsentSource {
    /// `record` is the plugin's, `changedHere` whether its folder no longer is
    /// what was installed, `recordsReadable` whether `installed.json` could be
    /// read — when it cannot, nothing says where any copy came from.
    public static func of(_ record: InstalledRecord?, basis: ConsentBasis, recordsReadable: Bool,
                          changedHere: Bool) -> Phrase? {
        guard basis == .tree else { return nil }
        guard recordsReadable else { return .permissionsSourceUnknown }
        guard let record, !record.isOfficialDefault else { return nil }
        return .permissionsUnverifiedSource(ref: record.ref, repository: record.repository.description,
                                            changedHere: changedHere)
    }
}
