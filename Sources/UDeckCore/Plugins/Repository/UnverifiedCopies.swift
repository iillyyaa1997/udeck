import Foundation

// What uDeck says of a copy installed from a branch or a pull request — code
// nobody verified — wherever it shows one: the row in Settings, the catalogue
// row of the same id, the card's header and its question, and a warning
// before one copy takes the place of a copy from somewhere else. Each said in
// one place, here, where it is tested; the views only show it.

/// A copy of a plugin as a sentence names it — where it came from, and which
/// one: *the verified 1.1.0 from github.com/…*, *1.0.1 from pull request #3 at
/// a1b2c3d*, *1.0.1 from branch fix/uptime at a1b2c3d*, *1.0.1 from branch fix
/// of someone/udeck-plugins at a1b2c3d*. What a warning that puts a copy from
/// one line of history in the place of a copy from another says of each
/// (`ShownPlace.Switch`): both sources and the ref, before anything is
/// replaced.
public enum CopyName: Equatable, Sendable {
    /// From the official source's default branch, whose copies are verified.
    case verified(version: String, repository: String)
    /// From the default branch of a source of one's own, at `address`
    /// (`host/path`): *1.1.0 from gitlab.example/tools/udeck-plugins:
    /// unverified* — or, once it is trusted, *…: trusted source* `trustedName`
    /// (`SourceName.shown`). Never verified, trusted or not.
    case sourceDefault(version: String, address: String, trustedName: String? = nil)
    /// From pull request `number`, at `commit` — its first seven characters.
    case pullRequest(number: Int, commit: String, version: String)
    /// From branch `name`, at `commit` — of `fork`, `owner/repo`, when it is a
    /// fork's branch (`PluginOrigin.fork`).
    case branch(name: String, commit: String, version: String, fork: String? = nil)
    /// From a line of history this uDeck does not know, at `commit`.
    case other(commit: String, version: String)

    /// `version` at `commit`, from `origin`, `official` being the official
    /// repository: a branch of another repository is named with its fork, and
    /// a default branch is the verified copy only when it is the official
    /// source's — another source's is named with its address, and with its
    /// name from `trustedNames`, by source id, when it is trusted.
    public static func of(_ origin: PluginOrigin, commit: String, version: String,
                          official: RepositoryAddress? = nil, trustedNames: [String: String] = [:]) -> CopyName {
        let short = String(commit.prefix(7))
        if origin.ref.isDefault {
            guard origin.source == InstalledPlugins.officialSource else {
                return .sourceDefault(version: version, address: origin.repository.description,
                                      trustedName: trustedNames[origin.source])
            }
            return .verified(version: version, repository: origin.repository.description)
        }
        if let number = origin.ref.pullRequestNumber { return .pullRequest(number: number, commit: short, version: version) }
        if origin.ref.kind == PluginRef.branchKind, let name = origin.ref.name {
            return .branch(name: name, commit: short, version: version, fork: origin.fork(official: official))
        }
        return .other(commit: short, version: version)
    }

    /// The same name, byte for byte: two spellings of a branch are two branches.
    static func same(_ one: CopyName, _ other: CopyName) -> Bool {
        switch (one, other) {
        case (.verified(let v1, let r1), .verified(let v2, let r2)):
            ShownPlace.same(v1, v2) && ShownPlace.same(r1, r2)
        case (.sourceDefault(let v1, let a1, let n1), .sourceDefault(let v2, let a2, let n2)):
            ShownPlace.same(v1, v2) && ShownPlace.same(a1, a2) && ShownPlace.same(n1, n2)
        case (.pullRequest(let n1, let c1, let v1), .pullRequest(let n2, let c2, let v2)):
            n1 == n2 && ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2)
        case (.branch(let b1, let c1, let v1, let f1), .branch(let b2, let c2, let v2, let f2)):
            ShownPlace.same(b1, b2) && ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2) && ShownPlace.same(f1, f2)
        case (.other(let c1, let v1), .other(let c2, let v2)):
            ShownPlace.same(c1, c2) && ShownPlace.same(v1, v2)
        default:
            false
        }
    }
}

extension PluginOrigin {
    /// The fork a branch is in, `owner/repo`, as a sentence names it after the
    /// branch — *branch fix of someone/udeck-plugins* — when it is not the
    /// official repository's (`official`) own, whatever case it is spelt in.
    /// Nil for the official repository's branches, for a pull request — read
    /// through the official repository, whoever opened it — for the default
    /// branch, and when the official repository is not known.
    public func fork(official: RepositoryAddress?) -> String? {
        guard ref.kind == PluginRef.branchKind, let official else { return nil }
        let same = repository.provider == official.provider && repository.host == official.host
            && repository.path.lowercased() == official.path.lowercased()
        return same ? nil : repository.path
    }

    /// Whether a copy from `other` follows the same line of history as a copy
    /// from here: the default branch of the same source — whatever its
    /// repository is called now, a rename is no other source; the default
    /// branches of two sources are two lines — or the same branch, or the
    /// same pull request, of the same repository and the same source, its
    /// name byte for byte. A copy from another line taking a copy's place is a
    /// switch of source, and its warning names both (`ShownPlace.Switch`).
    public func followsTheSameLine(as other: PluginOrigin) -> Bool {
        guard source == other.source else { return false }
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
    /// *pull request #3 at a1b2c3d*, *branch fix/uptime at a1b2c3d* or —
    /// a fork's branch — *branch fix of someone/udeck-plugins at a1b2c3d* for
    /// code nobody verified, after **Unverified**; `official` being the
    /// official repository. A copy of a source of one's own that is no
    /// longer among `sources`, the sources added — when they are known — says
    /// so: *From gitlab.example/tools/udeck-plugins — a source no longer added*.
    public func fromPhrase(official: RepositoryAddress?, sources: [OwnSource]? = nil) -> Phrase {
        let commit = String(self.commit.prefix(7))
        if let number = ref.pullRequestNumber {
            return .pluginFromPullRequest(number: number, commit: commit)
        }
        if ref.kind == PluginRef.branchKind, let name = ref.name {
            return .pluginFromBranch(name: name, commit: commit, fork: origin.fork(official: official))
        }
        if source != InstalledPlugins.officialSource, let sources, !sources.contains(where: { $0.id == source }) {
            return .sourceNoLongerAdded(address: repository.description)
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
    /// (`Adoption`). A fork's branch is named with its fork, `official` being
    /// the official repository. Only the official source's copies are
    /// adopted: a copy of a source of one's own comes back as that source's
    /// whatever the official catalogue's head has, and is said.
    public func reinstallSays(headTree: String?, official: RepositoryAddress? = nil) -> Phrase? {
        guard !isOfficialDefault else { return nil }
        guard source != InstalledPlugins.officialSource || tree != headTree else { return nil }
        return .windowReinstallBrings(CopyName.of(origin, commit: commit, version: version, official: official))
    }
}

extension UpdateOffer {
    /// What a row offers for an installed copy against the catalogue's head
    /// `entry`: `UpdateOffer.of` for a copy of the default branch — and
    /// nothing for code nobody verified. A branch's or a pull request's copy
    /// is not an older or a changed version of the catalogue's: the verified
    /// copy is offered as the switch it is (`CatalogueRowState.unverified`),
    /// never as an update, so nothing waits, and nothing updates by itself.
    /// `source` is the source whose catalogue's head `entry` is: a copy of
    /// another source's default branch is offered nothing from it — a copy of
    /// a source of one's own is offered updates from that source's head
    /// alone.
    public static func offered(_ record: InstalledRecord, head entry: CatalogueEntry?,
                               source: String = InstalledPlugins.officialSource) -> UpdateOffer? {
        guard record.source == source, record.ref.isDefault else { return nil }
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
    /// cannot. Nil for every other state. `fork` is the fork the branch is
    /// in, when it is one's (`PluginOrigin.fork`); `source`, the address of
    /// the source of one's own the copy came from, when it did — its default
    /// branch named by it: *Installed here from gitlab.example/tools/x:
    /// unverified*.
    public func unverifiedLine(ref: PluginRef, fork: String? = nil, id: String, path: String,
                               lifecycle: PullRequestLifecycle? = nil, source: String? = nil) -> [Phrase]? {
        guard case .unverified(_, let refusal, let folderGone) = self else { return nil }
        let installed: Phrase = source.flatMap { ref.isDefault ? .catalogueInstalledFromSource(address: $0) : nil }
            ?? .catalogueInstalledUnverified(ref: ref, fork: fork)
        return [installed]
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
/// github.com/…, not from what the repository merged.* — or, for the default
/// branch of a source of one's own, which merged it but nobody vouches for:
/// *Nobody verified this code: it comes from the default branch of
/// gitlab.example/…, a source you have not trusted.* Nothing for a decision
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
        if record.ref.isDefault {
            return .permissionsUntrustedSource(address: record.repository.description, changedHere: changedHere)
        }
        return .permissionsUnverifiedSource(ref: record.ref, repository: record.repository.description,
                                            changedHere: changedHere)
    }
}

/// What the branch or the pull request a copy of code nobody verified came
/// from has for it now, against the copy installed: an update along that line
/// — *Changed in pull request #3, still 1.0.1*, **Update** and *What changed* —
/// and whether the head that brings it continues what is installed or its
/// history was rewritten (`HistoryRewrite`). Offered, never made by itself:
/// **Update** installs that head's folder, and the card asks about it, as about
/// any new content of code nobody verified (`ConsentBasis`).
public struct RefOffer: Equatable, Sendable {
    /// The commit the line's head is at.
    public var head: String
    /// The copy's folder there against the one installed (`UpdateOffer.of`):
    /// never `.current`, which offers nothing.
    public var offer: UpdateOffer
    /// The head does not continue the commit installed.
    public var rewritten: Bool

    public init(head: String, offer: UpdateOffer, rewritten: Bool) {
        self.head = head
        self.offer = offer
        self.rewritten = rewritten
    }

    /// What `record`'s line offers: `heard` being the head it was last heard
    /// at with what was found of it (`FollowedRefs.head`), and `head` that
    /// head as the cache holds it (`RefHead`) — nil while the head is the
    /// commit installed, before the head's listing is read, and when the
    /// copy's folder there is the copy's.
    public static func of(_ record: InstalledRecord, heard: (commit: String, history: HeadHistory?)?,
                          head: RefHead?) -> RefOffer? {
        guard !record.isOfficialDefault, let heard, heard.commit != record.commit,
              let head, head.commit == heard.commit else { return nil }
        let offer = UpdateOffer.of(record, head: head.entry)
        guard offer != .current else { return nil }
        let rewritten = heard.history.map { $0.holds(installed: record.commit, head: heard.commit) && $0.rewritten } ?? false
        return RefOffer(head: heard.commit, offer: offer, rewritten: rewritten)
    }

    /// What the row says of it, `ref` being the line and `id` the plugin's:
    /// *1.0.2 available in pull request #3*, *Changed in branch fix/uptime,
    /// still 1.0.1*, *Pull request #3 now has 1.0.0*, *uptime is no longer in
    /// pull request #3; the plugin keeps running*, or why the version there
    /// cannot run here — one line, its parts joined; a fork's branch named
    /// with its `fork`.
    public func said(ref: PluginRef, fork: String? = nil, id: String) -> [Phrase] {
        switch offer {
        case .current: []
        case .newer(let version): [.pluginRefAvailable(ref: ref, version: version, fork: fork)]
        case .changedStill(let version): [.pluginRefChangedStill(ref: ref, version: version, fork: fork)]
        case .older(let version): [.pluginRefNowHas(ref: ref, version: version, fork: fork)]
        case .goneFromRepository: [.pluginRefGone(ref: ref, id: id, fork: fork)]
        case .cannotRun(let version, let reason):
            switch reason {
            case .apiNotSpoken(_, _, let api): [.catalogueUpdateNeedsAPI(version: version, api: api)]
            case .needsNewerUDeck(_, _, let required, _): [.catalogueUpdateNeedsUDeck(version: version, required: required)]
            default: [.catalogueUpdateCannotInstall(version: version), .catalogueRefusal(reason)]
            }
        }
    }

    /// The button that goes with it: **Update** for a newer version or other
    /// files, **Switch to** an older one; none for a folder that is not there
    /// or a version that cannot run here.
    public var button: Phrase? {
        switch offer {
        case .newer, .changedStill: .catalogueUpdate
        case .older(let version): .catalogueSwitchTo(version: version)
        case .current, .goneFromRepository, .cannotRun: nil
        }
    }
}

/// What the rows of a copy of code nobody verified — installed from a branch or
/// a pull request — say and offer beyond its mark: what became of its pull
/// request, what its line has for it now, its branch gone, a line not checked
/// in the last read, and the verified copy that can take its place. Decided
/// here, whole, where it is tested; UDeckKit has no tests, and its views only
/// show this.
public struct UnverifiedRow: Equatable, Sendable {
    /// What became of its pull request (`PullRequestLifecycle`); nil for a
    /// branch's copy, and before anything was heard.
    public var lifecycle: PullRequestLifecycle?
    /// The version of the catalogue's verified copy, which can be put in its
    /// place here — nil when the catalogue does not have the plugin, cannot
    /// install it here, or is switched off.
    public var verifiedVersion: String?
    /// What its branch or pull request has for it now (`RefOffer`) — never
    /// while the catalogue is off, for a branch that is not there, or once its
    /// pull request was merged into the default branch: what was merged is
    /// what it is offered then.
    public var lineOffer: RefOffer?
    /// Its branch is not there any more: said, and the plugin keeps running.
    public var branchGone: Bool
    /// The last read did not ask about its line — the reserve, a limit, a
    /// request that failed, a read of the catalogue left for later or failed
    /// before it got there: when it was last asked about. Nil while the
    /// catalogue is off: then nothing is asked at all, as Settings says.
    public var notCheckedSince: Date?

    public init(lifecycle: PullRequestLifecycle?, verifiedVersion: String?, lineOffer: RefOffer?, branchGone: Bool,
                notCheckedSince: Date?) {
        self.lifecycle = lifecycle
        self.verifiedVersion = verifiedVersion
        self.lineOffer = lineOffer
        self.branchGone = branchGone
        self.notCheckedSince = notCheckedSince
    }

    /// The row of `id`, whose record is `record` — nil for the default
    /// branch's copy, and where uDeck installed nothing — `followed` being
    /// what was heard of its line, `head` its moved head as the cache holds it,
    /// `defaultBranch` the official source's, `readsCatalogue` whether
    /// **Official catalogue** is on, and `verified` the catalogue's row of the
    /// same id.
    public static func of(_ id: String, record: InstalledRecord?, followed: FollowedRefs, head: RefHead?,
                          defaultBranch: String?, readsCatalogue: Bool, verified entry: CatalogueEntry?) -> UnverifiedRow? {
        guard let record, !record.isOfficialDefault else { return nil }
        var verifiedVersion: String?
        // Its folder there or gone, the same verified copy is offered.
        if readsCatalogue, let entry,
           case .unverified(let version, nil, _) = CatalogueRowState.of(entry, record: record, folderExists: true) {
            verifiedVersion = version
        }
        let branch = followed.branch(of: id, record: record)
        return UnverifiedRow(
            lifecycle: PullRequestLifecycle.of(record, followed: followed.pull(of: id, record: record),
                                               defaultBranch: defaultBranch, verifiedOffered: verifiedVersion != nil),
            verifiedVersion: verifiedVersion,
            lineOffer: readsCatalogue
                ? RefOffer.of(record, heard: followed.head(of: id, record: record, defaultBranch: defaultBranch), head: head)
                : nil,
            branchGone: branch != nil && branch?.head == nil,
            notCheckedSince: readsCatalogue ? followed.notCheckedSince[id] : nil
        )
    }

    /// Whether the verified copy is offered as the update it is — its pull
    /// request merged as something else: *the verified version differs —
    /// update* — rather than as a switch.
    public var verifiedIsAnUpdate: Bool { lifecycle == .mergedDiffers && verifiedVersion != nil }

    /// What the button that puts the verified copy in its place says — one
    /// name for one press, on the plugin's row and on the catalogue row alike:
    /// **Update** once its pull request was merged as something else, which
    /// its row says to do, and **Switch to verified 1.0.0** otherwise. Nil
    /// when there is no verified copy to put there.
    public var verifiedButton: Phrase? {
        guard let verifiedVersion else { return nil }
        return verifiedIsAnUpdate ? .catalogueUpdate : .catalogueSwitchToVerified(version: verifiedVersion)
    }

    /// Whether it counts among the updates Settings says are waiting: the
    /// verified version offered as an update, or a newer version or other
    /// files along its own line.
    public var waiting: Bool { verifiedIsAnUpdate || lineOffer?.offer.isWaiting == true }

    /// One line the row says under its mark, and the end of its identifier
    /// (`plugin.<id>.<suffix>`).
    public struct Said: Equatable, Sendable {
        public var suffix: String
        public var phrase: [Phrase]
    }

    /// What the plugin's row says under its mark, in order, `ref` being where
    /// the copy came from — of `fork`, when that is a fork's branch
    /// (`PluginOrigin.fork`) — and `time` how a moment is written: what became
    /// of its pull request; its branch gone; its line's history rewritten;
    /// what its line offers; and since when that line was not checked.
    public func said(ref: PluginRef, fork: String? = nil, id: String, time: (Date) -> String) -> [Said] {
        var said: [Said] = []
        if let number = ref.pullRequestNumber, let phrase = lifecycle?.rowPhrase(number: number) {
            said.append(Said(suffix: "pullRequest", phrase: [phrase]))
        }
        if branchGone, ref.kind == PluginRef.branchKind, let name = ref.name {
            said.append(Said(suffix: "branchGone", phrase: [.pluginBranchGone(name: name, fork: fork)]))
        }
        if let lineOffer {
            if lineOffer.rewritten {
                said.append(Said(suffix: "rewritten", phrase: [.pluginRefRewritten(ref: ref, fork: fork)]))
            }
            said.append(Said(suffix: "offer", phrase: lineOffer.said(ref: ref, fork: fork, id: id)))
        }
        if let notCheckedSince {
            said.append(Said(suffix: "notChecked",
                             phrase: [.pluginRefNotCheckedSince(ref: ref, at: time(notCheckedSince), fork: fork)]))
        }
        return said
    }
}
