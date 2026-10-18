import Foundation

/// One plugin a repository offers, as its catalogue row knows it — all of it
/// from the listing and the manifest, so none of it cost a download.
public struct CatalogueEntry: Equatable, Sendable, Identifiable {
    /// The folder's name under `plugins/`.
    public var id: String
    public var listing: PluginListing
    /// The manifest, when it could be read, and every reason it cannot be
    /// installed here.
    public var verdict: RepositoryRules.Verdict
    /// Translations that were fetched: only the language the panel speaks, and
    /// only when the listing has one.
    public var translations: [String: ManifestTranslation]

    public init(id: String, listing: PluginListing, verdict: RepositoryRules.Verdict,
                translations: [String: ManifestTranslation] = [:]) {
        self.id = id
        self.listing = listing
        self.verdict = verdict
        self.translations = translations
    }

    public var manifest: PluginManifest? { verdict.manifest }

    /// The manifest as the operator reads it, in `language` where there is a
    /// translation.
    public func manifest(in language: String) -> PluginManifest? {
        guard let manifest else { return nil }
        guard let translation = translations[language.lowercased()] else { return manifest }
        return manifest.applying(translation)
    }

    /// The name a row is sorted and shown by: the manifest's, or the folder's.
    public func name(in language: String) -> String {
        let name = manifest(in: language)?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id : name
    }
}

/// A repository's catalogue at one commit, as uDeck shows it in Settings →
/// Plugins.
public struct Catalogue: Equatable, Sendable {
    public var address: RepositoryAddress
    public var commit: String
    public var branch: String?
    public var passport: RepositoryPassport
    /// Sorted by name, as the operator reads it.
    public var entries: [CatalogueEntry]
    /// The source it is the catalogue of: `official`, or a source of one's
    /// own by its id (`SourceID`) — what its copies are recorded as.
    public var source: String

    public init(address: RepositoryAddress, commit: String, branch: String?,
                passport: RepositoryPassport, entries: [CatalogueEntry],
                source: String = InstalledPlugins.officialSource) {
        self.address = address
        self.commit = commit
        self.branch = branch
        self.passport = passport
        self.entries = entries
        self.source = source
    }

    public func entry(_ id: String) -> CatalogueEntry? { entries.first { $0.id == id } }

    /// `load`, away from the main thread: what uDeck calls.
    ///
    /// A catalogue is every manifest a repository has — files of somebody
    /// else's, of any size up to the rules' limit — each read from disk,
    /// hashed again and parsed strictly. On the main thread that is the panel
    /// and Settings standing still while it happens, for a reason the
    /// operator cannot see. `nonisolated` and `async`, so it runs on the
    /// cooperative pool whoever awaits it; `CatalogueStore.blob` holds every
    /// path that reads one to that (an assertion, in builds that keep them).
    public static func read(
        from store: CatalogueStore,
        address: RepositoryAddress,
        udeck: SemanticVersion?,
        language: String,
        source: String = InstalledPlugins.officialSource
    ) async -> Catalogue? {
        load(from: store, address: address, udeck: udeck, language: language, source: source)
    }

    /// The catalogue as the cache holds it, or nil when there is nothing to
    /// show yet. This is what makes it appear at once when Settings opens,
    /// before any request answers. `source` is the source it is the
    /// catalogue of.
    public static func load(
        from store: CatalogueStore,
        address: RepositoryAddress,
        udeck: SemanticVersion?,
        language: String,
        source: String = InstalledPlugins.officialSource
    ) -> Catalogue? {
        let state = store.state()
        guard let head = state.head, let listing = store.listing(head) else { return nil }
        guard case .success(let passport) = RepositoryPassport.read(listing.passport.flatMap(store.blob)) else {
            return nil
        }
        let entries = listing.pluginFolders.compactMap { folder -> CatalogueEntry? in
            guard let plugin = listing.plugins[folder] else { return nil }
            return entry(folder, plugin, store: store, udeck: udeck, language: language)
        }
        return Catalogue(
            address: address, commit: head, branch: state.defaultBranch, passport: passport,
            entries: entries.sorted {
                $0.name(in: language).localizedStandardCompare($1.name(in: language)) == .orderedAscending
            },
            source: source
        )
    }

    /// One folder of a cached listing as a row: its rules checked, its
    /// manifest and its translation read out of the blob store.
    public static func entry(
        _ folder: String,
        _ plugin: PluginListing,
        store: CatalogueStore,
        udeck: SemanticVersion?,
        language: String
    ) -> CatalogueEntry {
        let manifestData = plugin.file(at: PluginDiscovery.manifestFilename).flatMap { store.blob($0.sha) }
        let verdict = RepositoryRules.check(folder: folder, listing: plugin, manifest: manifestData, udeck: udeck)
        var translations: [String: ManifestTranslation] = [:]
        let code = language.lowercased()
        if let file = plugin.file(at: "manifest.\(code).json"), let data = store.blob(file.sha),
           let translation = try? JSONDecoder().decode(ManifestTranslation.self, from: data) {
            translations[code] = translation
        }
        return CatalogueEntry(id: folder, listing: plugin, verdict: verdict, translations: translations)
    }
}

/// What the repository has for a plugin that was installed from it, compared
/// with what was installed — a comparison of two hashes, and no download.
public enum UpdateOffer: Equatable, Sendable {
    /// The folder at the head is the tree that was installed.
    case current
    /// A newer version: *1.3.0 available*, **Update**.
    case newer(version: String)
    /// The same version, different files: *Changed in the repository, still
    /// 1.2.0*, **Update**.
    case changedStill(version: String)
    /// The repository went back: *The repository now has 1.1.0*, **Switch to**.
    case older(version: String)
    /// A different version that cannot run here: said, and nothing offered.
    /// The installed copy keeps running.
    case cannotRun(version: String, reason: RepositoryRefusal)
    /// The folder is not in the repository any more: **Remove**, and the
    /// plugin keeps running.
    case goneFromRepository

    /// Whether this is one of the updates Settings counts as waiting.
    public var isWaiting: Bool {
        switch self {
        case .newer, .changedStill: true
        default: false
        }
    }


    /// Compares an installed record with the head's entry for the same id.
    public static func of(_ record: InstalledRecord, head entry: CatalogueEntry?) -> UpdateOffer {
        guard let entry else { return .goneFromRepository }
        guard entry.listing.tree != record.tree else { return .current }
        guard let manifest = entry.manifest else {
            return .cannotRun(version: "?", reason: entry.verdict.refusals.first
                              ?? .noManifest(path: "plugins/\(entry.id)/manifest.json"))
        }
        if let first = entry.verdict.refusals.first {
            return .cannotRun(version: manifest.version, reason: first)
        }
        switch (SemanticVersion(manifest.version), SemanticVersion(record.version)) {
        case (let new?, let old?) where new > old: return .newer(version: manifest.version)
        case (let new?, let old?) where new < old: return .older(version: manifest.version)
        default:
            return manifest.version == record.version
                ? .changedStill(version: manifest.version) : .newer(version: manifest.version)
        }
    }
}

/// A catalogue row's state, and so the one button that goes with it.
public enum CatalogueRowState: Equatable, Sendable {
    /// Not installed: **Install**.
    case notInstalled
    /// Cannot be installed here: the first reason, and every reason under
    /// Details. Nothing of the plugin but its manifest was downloaded.
    case cannotInstall(RepositoryRefusal)
    /// A folder of the operator's own has this id: **Replace…**.
    case folderOfYourOwn
    /// Installed from here, and what the repository has for it now.
    case installed(UpdateOffer)
    /// Installed from here, and its folder is gone: **Reinstall**.
    case missing
    /// Installed from a branch or a pull request — code nobody verified — in
    /// the place of the copy this row offers, which is verified: **Switch to
    /// verified** `version`. When that copy cannot be installed here,
    /// `refusal` says why and nothing is offered; the copy on disk keeps
    /// running either way. `folderGone`: its folder is gone too, and the row
    /// says that as well — **Switch to verified** then puts the verified copy
    /// where nothing is, and **Reinstall** on the plugin's own row puts the
    /// pull request's back, saying where it comes from. Never **Reinstall**
    /// here: a catalogue row's button brings the catalogue's copy.
    case unverified(version: String, refusal: RepositoryRefusal?, folderGone: Bool = false)
    /// In the catalogue of a source of one's own: the id is installed from
    /// somewhere else — the official source, or another source — as `copy`
    /// names it, in the place of the copy this row offers, `version`:
    /// **Install from here…**, a replace that names both first
    /// (`ShownPlace.Switch`), never one made unsaid. When this row's copy
    /// cannot be installed here, `refusal` says why and nothing is offered;
    /// `folderGone`: the copy's folder is gone too.
    case fromElsewhere(CopyName, version: String, refusal: RepositoryRefusal?, folderGone: Bool = false)

    /// The state of `entry`'s row in the catalogue of `source` — the
    /// official one, or a source of one's own by its id — `record` being the
    /// record of the same id. A copy of this source's default branch is
    /// measured against this source's head. In the official catalogue
    /// anything else is the copy of code nobody verified it always was
    /// (`unverified`) — a source of one's own's included, whose
    /// `unverifiedLine` names it — with **Switch to verified**; in a source of
    /// one's own's, anything else is from elsewhere (`fromElsewhere`), `official`
    /// naming a fork's branch there.
    public static func of(
        _ entry: CatalogueEntry,
        record: InstalledRecord?,
        folderExists: Bool,
        source: String = InstalledPlugins.officialSource,
        official: RepositoryAddress? = nil
    ) -> CatalogueRowState {
        if let record {
            let refusal = entry.verdict.refusals.first
                ?? (entry.manifest == nil ? .noManifest(path: "plugins/\(entry.id)/manifest.json") : nil)
            let version = entry.manifest?.version ?? "?"
            guard record.source == source, record.ref.isDefault else {
                // Code nobody verified is said first, its folder there or
                // not: a row that said only "missing" offered **Reinstall**,
                // which put the pull request's copy back under the row's
                // **Verified** (R3's review).
                guard source == InstalledPlugins.officialSource else {
                    return .fromElsewhere(CopyName.of(record.origin, commit: record.commit, version: record.version,
                                                      official: official),
                                          version: version, refusal: refusal, folderGone: !folderExists)
                }
                return .unverified(version: version, refusal: refusal, folderGone: !folderExists)
            }
            guard folderExists else { return .missing }
            return .installed(UpdateOffer.of(record, head: entry))
        }
        if let first = entry.verdict.refusals.first { return .cannotInstall(first) }
        if entry.manifest == nil { return .cannotInstall(.noManifest(path: "plugins/\(entry.id)/manifest.json")) }
        return folderExists ? .folderOfYourOwn : .notInstalled
    }
}
