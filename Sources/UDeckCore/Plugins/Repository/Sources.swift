import CryptoKit
import Foundation

// The sources the operator adds beside the built-in official one (stage 4):
// `~/.udeck/sources.json`, the id each source is known by, and what a source
// is called on screen. The official source is not in the file: it stays
// built in, from `Info.plist`. See docs/plugin-repository.md.

/// What a source is, whatever it is called now: its provider, its host, and
/// the number the host knows the repository or the project by — GitHub's
/// repository id, GitLab's project id — which neither a rename nor a
/// transfer changes, and which a repository made later at the old name does
/// not have.
public struct SourceIdentity: Hashable, Sendable, CustomStringConvertible {
    public var provider: String
    /// Lowercased.
    public var host: String
    public var remoteID: Int

    public init(provider: String, host: String, remoteID: Int) {
        self.provider = provider
        self.host = host.lowercased()
        self.remoteID = remoteID
    }

    public var description: String { "\(provider) \(host) #\(remoteID)" }
}

/// A source's id: `<slug>-<hash8>`, what `installed.json` says a copy came
/// from (`source`, `verification.by`), the name of its folder under
/// `~/.udeck/catalogue/`, and the key of its token.
///
/// `hash8` is the first 8 hexadecimal digits of SHA-256 over
/// `<provider>\n<lowercased host>\n<remoteID>`: the id belongs to the
/// repository, so a renamed one keeps it and a new one made at the old name
/// gets another — and records, the folder and the token reconnect only to the
/// repository they were made for. `slug` is only for a person reading
/// `~/.udeck`: the lowercased host, `-`, and the last segment of the path
/// when the source was added, every character outside `[a-z0-9.-]` made a
/// `-`, runs of `-` made one, cut at 40. So an id always matches
/// `^[a-z0-9][a-z0-9.-]{0,40}-[0-9a-f]{8}$`: it is never `official`, and it is
/// always a safe folder name.
public enum SourceID {
    /// The longest a slug is cut to.
    public static let slugLimit = 40

    /// The id of `identity`, added at `path`.
    public static func derive(_ identity: SourceIdentity, path: String) -> String {
        "\(slug(host: identity.host, path: path))-\(hash8(identity))"
    }

    /// The first 8 hexadecimal digits of SHA-256 over the identity.
    public static func hash8(_ identity: SourceIdentity) -> String {
        let digest = SHA256.hash(data: Data("\(identity.provider)\n\(identity.host)\n\(identity.remoteID)".utf8))
        return digest.prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// The part of an id that is for reading.
    static func slug(host: String, path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        var slug = ""
        for scalar in "\(host)-\(last)".lowercased().unicodeScalars {
            let kept = ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) || scalar == "." || scalar == "-"
            let character: Character = kept ? Character(scalar) : "-"
            if character == "-", slug.last == "-" { continue }
            slug.append(character)
        }
        while let first = slug.unicodeScalars.first, first == "-" || first == "." { slug.removeFirst() }
        slug = String(slug.prefix(slugLimit))
        while slug.last == "-" { slug.removeLast() }
        return slug.isEmpty ? "source" : slug
    }

    /// Whether `id` has the shape of a source's id.
    public static func isWellFormed(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (10 ... 10 + slugLimit).contains(scalars.count) else { return false }
        let hash = scalars.suffix(8)
        let slug = scalars.dropLast(9)
        func letterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar)
        }
        return scalars[scalars.count - 9] == "-"
            && hash.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
            && slug.first.map(letterOrDigit) == true
            && slug.allSatisfy { letterOrDigit($0) || $0 == "." || $0 == "-" }
    }

    /// Whether `id` is the one derived from `identity`: its shape, and its
    /// hash — the slug says the path at the time it was added, which a rename
    /// changes since.
    public static func isDerived(_ id: String, from identity: SourceIdentity) -> Bool {
        isWellFormed(id) && id.hasSuffix("-\(hash8(identity))")
    }
}

/// A source the operator added: one entry of `~/.udeck/sources.json`.
public struct OwnSource: Equatable, Sendable {
    /// What the Keychain is expected to hold for the source — never the
    /// token itself.
    public enum Access {
        public static let none = "none"
        public static let token = "token"
        public static let signIn = "signIn"
    }

    public var id: String
    /// `github` or `gitlab`.
    public var provider: String
    /// Lowercased, with a port when it has one.
    public var host: String
    /// `owner/repo`, or `group/…/project`, as the host spells it now: for the
    /// links a person reads, and GitHub's raw host. Every request after the
    /// add addresses the repository by `remoteID`.
    public var path: String
    public var remoteID: Int
    /// `none`, `token` or `signIn`, as written — a kind a later uDeck writes
    /// is kept as it is.
    public var access: String
    /// When the operator trusted it, or nil.
    public var trustedAt: Date?
    /// When it was added.
    public var addedAt: Date?

    public init(id: String, provider: String, host: String, path: String, remoteID: Int, access: String = Access.none,
                trustedAt: Date? = nil, addedAt: Date?) {
        self.id = id
        self.provider = provider
        self.host = host
        self.path = path
        self.remoteID = remoteID
        self.access = access
        self.trustedAt = trustedAt.map(InstalledPlugins.wholeSeconds)
        self.addedAt = addedAt.map(InstalledPlugins.wholeSeconds)
    }

    public var identity: SourceIdentity { SourceIdentity(provider: provider, host: host, remoteID: remoteID) }

    /// The repository or the project, as a record and a sentence name it.
    public var address: RepositoryAddress { RepositoryAddress(provider: provider, host: host, path: path) }

    /// Whether `repository` is this source's current address: its provider
    /// and host, and its path — whatever its case on GitHub, which reads
    /// names that way, and byte for byte on GitLab.
    public func isAt(_ repository: RepositoryAddress) -> Bool {
        guard repository.provider == provider, repository.host.lowercased() == host else { return false }
        return provider == SourceLink.github ? repository.path.lowercased() == path.lowercased() : repository.path == path
    }
}

/// `~/.udeck/sources.json`: the sources the operator added, in the order
/// Settings shows them.
///
/// ```json
/// {"version": 1, "sources": [{"id": "gitlab.unicorns.place-udeck-plugins-<hash8>", "provider": "gitlab",
///   "host": "gitlab.unicorns.place", "path": "tools/udeck-plugins", "remoteID": 48, "access": "token",
///   "trustedAt": null, "addedAt": "2026-10-20T10:00:00Z"}]}
/// ```
///
/// Written atomically through `JSONFileStore`, like `installed.json`, and
/// never with a secret in it. Read tolerantly where it can be: a key this
/// uDeck does not know is ignored, and written back as it was; an entry it
/// cannot use — a provider it does not know, no `remoteID`, a host or a path
/// `SourceLink` would refuse — is skipped, named on the problem line, and
/// written back as it was. Read strictly where it matters: the whole file is
/// broken when an entry's id is not the one derived from its identity
/// (`SourceID`), when two entries share an id or an identity — skipped
/// entries counted — and when it does not parse. A broken file is
/// reported and never overwritten (`SourceStore`), and while it is broken no
/// source of the operator's is read, added or removed.
///
/// Not a boundary against plugins: a plugin runs as the operator and can write
/// this file, as it can write `grants.json` and the plugin folders. What a
/// token is sent to is bound in the Keychain, not decided here.
public struct SourceList: Equatable, Sendable {
    public var version: Int
    /// Every entry, in the file's order.
    public private(set) var entries: [Entry]

    public enum Entry: Equatable, Sendable {
        case source(OwnSource)
        case skipped(Skipped)
    }

    /// An entry this uDeck cannot use, kept as it was written.
    public struct Skipped: Equatable, Sendable {
        /// Its place in the list, from 1.
        public var position: Int
        /// `host/path`, when the entry says both.
        public var named: String?
        public var reason: Skip
        /// The entry as it was read, written back as it is.
        var json: JSON

        /// The id it gives, if it gives one.
        public var id: String? { json.fields?["id"]?.string }

        /// The repository it says, when it names a provider this uDeck reads,
        /// a host and a `remoteID` above 0. Left out, it is still in the
        /// file: no other entry may be that repository, nor have its id.
        public var identity: SourceIdentity? {
            guard let fields = json.fields, let provider = fields["provider"]?.string,
                  provider == SourceLink.github || provider == SourceLink.gitlab,
                  let host = fields["host"]?.string, let remoteID = fields["remoteID"]?.integer, remoteID > 0 else {
                return nil
            }
            return SourceIdentity(provider: provider, host: host, remoteID: remoteID)
        }
    }

    /// Why an entry is skipped.
    public enum Skip: Equatable, Sendable {
        /// Not an object.
        case notAnEntry
        /// A provider this uDeck does not read — a later one's — or none.
        case unknownProvider(String?)
        /// No `remoteID`, or one that is not a whole number above 0.
        case noRemoteID
        /// A host or a path `SourceLink` refuses, or reads as another
        /// provider, host or path than the entry says (`readsAsAnother`).
        case address(SourceLink.Refusal)
    }

    /// Why the whole file is broken.
    public enum Broken: Error, Equatable, Sendable, CustomStringConvertible {
        /// It could not be read, or it is not JSON of this shape.
        case unreadable(String)
        /// An entry's id is not the one its identity gives — or it has none.
        case idNotDerived(id: String?, named: String)
        /// Two entries have this id.
        case sameID(String)
        /// Two entries are the same repository, at these two addresses.
        case sameRepository(String, String)

        public var description: String {
            switch self {
            case .unreadable(let detail): "sources.json cannot be read: \(detail)"
            case .idNotDerived(let id, let named): "sources.json gives \(named) the id \(id ?? "null"), which is not its own"
            case .sameID(let id): "sources.json gives two sources the id \(id)"
            case .sameRepository(let one, let other): "sources.json lists one repository twice: \(one) and \(other)"
            }
        }
    }

    /// Why **Add** adds nothing.
    public enum AddRefusal: Error, Equatable, Sendable {
        /// The same identity is listed already, as this source.
        case alreadyAdded(OwnSource)
        /// Another identity's id would be the same — a collision of the hash
        /// and the slug together, about 2^-32 for a pair.
        case idTaken(by: OwnSource)
        /// An address `SourceLink` would refuse, or read as another.
        case address(SourceLink.Refusal)
        /// An entry this uDeck leaves out is the same repository, or has the
        /// id the new one would: both in the file would make it broken. Its
        /// problem line says why it is left out (`Phrase.sourceSkipped`).
        case listedAsSkipped(Skipped)
    }

    /// Keys this uDeck does not know — a later one's — of the file, and of
    /// each source by its id: ignored, and written back as they were.
    var laterKeys: [String: JSON] = [:]
    var laterKeysOfSources: [String: [String: JSON]] = [:]

    public init(version: Int = 1, sources: [OwnSource] = []) {
        self.version = version
        self.entries = sources.map(Entry.source)
    }

    /// The sources this uDeck reads, in order.
    public var sources: [OwnSource] {
        entries.compactMap { if case .source(let source) = $0 { source } else { nil } }
    }

    /// The entries skipped, in order.
    public var skipped: [Skipped] {
        entries.compactMap { if case .skipped(let skipped) = $0 { skipped } else { nil } }
    }

    /// The source with this id.
    public func source(_ id: String) -> OwnSource? {
        sources.first { $0.id == id }
    }

    /// The source with this identity.
    public func source(identity: SourceIdentity) -> OwnSource? {
        sources.first { $0.identity == identity }
    }

    /// **Add**: a source with the id derived from its identity, added at
    /// `path`, at the end of the list — or why not: the same identity listed
    /// already, an id another identity has, an entry left out that is the
    /// same repository or has the same id, an address that would be skipped.
    @discardableResult
    public mutating func add(provider: String, host: String, path: String, remoteID: Int,
                             access: String = OwnSource.Access.none, at: Date,
                             official: RepositoryAddress = .official) -> Result<OwnSource, AddRefusal> {
        let identity = SourceIdentity(provider: provider, host: host, remoteID: remoteID)
        let source = OwnSource(id: SourceID.derive(identity, path: path), provider: provider, host: identity.host,
                               path: path, remoteID: remoteID, access: access, addedAt: at)
        if let refusal = SourceLink.refusal(of: source.address, official: official) { return .failure(.address(refusal)) }
        if let listed = self.source(identity: identity) { return .failure(.alreadyAdded(listed)) }
        if let taken = sources.first(where: { $0.id == source.id }) { return .failure(.idTaken(by: taken)) }
        if let left = skipped.first(where: { $0.identity == identity || $0.id == source.id }) {
            return .failure(.listedAsSkipped(left))
        }
        entries.append(.source(source))
        return .success(source)
    }

    /// **Remove**: the source with this id goes from the list.
    @discardableResult
    public mutating func remove(_ id: String) -> OwnSource? {
        guard let index = entries.firstIndex(where: { if case .source(let source) = $0 { source.id == id } else { false } }),
              case .source(let source) = entries[index] else { return nil }
        entries.remove(at: index)
        laterKeysOfSources[id] = nil
        return source
    }

    /// What the host spells the source's path as now, written back — the
    /// same id, the same repository. Nothing for a path `SourceLink` would
    /// not read as this source's.
    @discardableResult
    public mutating func respell(_ id: String, path: String, official: RepositoryAddress = .official) -> Bool {
        guard let index = entries.firstIndex(where: { if case .source(let source) = $0 { source.id == id } else { false } }),
              case .source(var source) = entries[index] else { return false }
        source.path = path
        guard SourceLink.refusal(of: source.address, official: official) == nil else { return false }
        entries[index] = .source(source)
        return true
    }

    // MARK: - Reading

    /// The key under which a decoder's `userInfo` names the official
    /// repository, which no entry may be (`SourceLink.Refusal.officialCatalogue`).
    public static let officialKey = CodingUserInfoKey(rawValue: "udeck.official")!

    /// `data` read, `official` being the official repository: the list, or
    /// why the whole file is broken.
    public static func read(_ data: Data, official: RepositoryAddress = .official) -> Result<SourceList, Broken> {
        let decoder = JSONFileStore<SourceList>.decoder
        decoder.userInfo[officialKey] = official
        do {
            return .success(try decoder.decode(SourceList.self, from: data))
        } catch let broken as Broken {
            return .failure(broken)
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    /// One entry of the file, as this uDeck can use it — or why not.
    static func entry(_ json: JSON, position: Int, official: RepositoryAddress) -> Entry {
        guard case .object(let fields) = json else {
            return .skipped(Skipped(position: position, named: nil, reason: .notAnEntry, json: json))
        }
        let host = fields["host"]?.string, path = fields["path"]?.string
        let named = host.flatMap { host in path.map { "\(host)/\($0)" } }
        func skipped(_ reason: Skip) -> Entry {
            .skipped(Skipped(position: position, named: named, reason: reason, json: json))
        }
        let provider = fields["provider"]?.string
        guard let provider, provider == SourceLink.github || provider == SourceLink.gitlab else {
            return skipped(.unknownProvider(provider))
        }
        guard let remoteID = fields["remoteID"]?.integer, remoteID > 0 else { return skipped(.noRemoteID) }
        guard let host, let path else { return skipped(.address(.notALink)) }
        if let refusal = SourceLink.refusal(of: RepositoryAddress(provider: provider, host: host, path: path),
                                            official: official) {
            return skipped(.address(refusal))
        }
        return .source(OwnSource(
            id: fields["id"]?.string ?? "", provider: provider, host: host, path: path, remoteID: remoteID,
            access: fields["access"]?.string ?? OwnSource.Access.none,
            trustedAt: fields["trustedAt"]?.string.flatMap(Self.date), addedAt: fields["addedAt"]?.string.flatMap(Self.date)
        ))
    }

    /// The rules that make the whole file broken, over every entry read.
    static func check(_ entries: [Entry], ids: [String?]) throws(Broken) {
        var seen = Set<String>()
        for id in ids.compactMap({ $0 }) {
            guard seen.insert(id).inserted else { throw .sameID(id) }
        }
        // Every entry that says a repository, read or left out, as with the ids.
        var identities: [SourceIdentity: String] = [:]
        for entry in entries {
            let identity: SourceIdentity, named: String
            switch entry {
            case .source(let source):
                guard SourceID.isDerived(source.id, from: source.identity) else {
                    throw .idNotDerived(id: source.id.isEmpty ? nil : source.id, named: source.address.description)
                }
                (identity, named) = (source.identity, source.address.description)
            case .skipped(let skipped):
                guard let said = skipped.identity else { continue }
                (identity, named) = (said, skipped.named ?? said.host)
            }
            if let other = identities[identity] { throw .sameRepository(other, named) }
            identities[identity] = named
        }
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// JSON as it was written, for an entry kept as it is.
    indirect enum JSON: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case integer(Int)
        case number(Double)
        case string(String)
        case array([JSON])
        case object([String: JSON])

        var string: String? { if case .string(let text) = self { text } else { nil } }
        var integer: Int? { if case .integer(let number) = self { number } else { nil } }
        var fields: [String: JSON]? { if case .object(let fields) = self { fields } else { nil } }

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Int.self) { self = .integer(value) }
            else if let value = try? c.decode(Double.self) { self = .number(value) }
            else if let value = try? c.decode(String.self) { self = .string(value) }
            else if let value = try? c.decode([JSON].self) { self = .array(value) }
            else { self = .object(try c.decode([String: JSON].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let value): try c.encode(value)
            case .integer(let value): try c.encode(value)
            case .number(let value): try c.encode(value)
            case .string(let value): try c.encode(value)
            case .array(let value): try c.encode(value)
            case .object(let value): try c.encode(value)
            }
        }
    }
}

extension SourceList: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, sources }
    private enum SourceKeys: String, CodingKey, CaseIterable {
        case id, provider, host, path, remoteID, access, trustedAt, addedAt
    }

    /// Any key: those this uDeck does not know, written back beside its own.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ key: String) { stringValue = key }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    /// `fields` but for the keys `known` names.
    private static func later<Key: CaseIterable & RawRepresentable>(_ fields: [String: JSON], than known: Key.Type)
        -> [String: JSON] where Key.RawValue == String {
        let names = Set(Key.allCases.map(\.rawValue))
        return fields.filter { !names.contains($0.key) }
    }

    public init(from decoder: any Decoder) throws {
        let official = decoder.userInfo[Self.officialKey] as? RepositoryAddress ?? .official
        let c: KeyedDecodingContainer<CodingKeys>
        let list: [JSON]
        do {
            c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            list = try c.decode([JSON].self, forKey: .sources)
            laterKeys = Self.later(try decoder.singleValueContainer().decode([String: JSON].self), than: CodingKeys.self)
        } catch {
            throw Broken.unreadable("\(error)")
        }
        entries = list.enumerated().map { Self.entry($1, position: $0 + 1, official: official) }
        for (json, entry) in zip(list, entries) {
            guard case .source(let source) = entry, let fields = json.fields else { continue }
            let later = Self.later(fields, than: SourceKeys.self)
            if !later.isEmpty { laterKeysOfSources[source.id] = later }
        }
        // Every id the file gives, read or skipped: two of one id would share
        // a catalogue folder and a token, whichever of them this uDeck reads.
        let ids = list.map { json -> String? in
            if case .object(let fields) = json { fields["id"]?.string } else { nil }
        }
        try Self.check(entries, ids: ids)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in laterKeys { try c.encode(value, forKey: AnyKey(key)) }
        try c.encode(version, forKey: AnyKey(CodingKeys.version.rawValue))
        var list = c.nestedUnkeyedContainer(forKey: AnyKey(CodingKeys.sources.rawValue))
        for entry in entries {
            switch entry {
            case .skipped(let skipped):
                try list.encode(skipped.json)
            case .source(let source):
                var fields = list.nestedContainer(keyedBy: AnyKey.self)
                for (key, value) in laterKeysOfSources[source.id] ?? [:] { try fields.encode(value, forKey: AnyKey(key)) }
                func key(_ key: SourceKeys) -> AnyKey { AnyKey(key.rawValue) }
                try fields.encode(source.id, forKey: key(.id))
                try fields.encode(source.provider, forKey: key(.provider))
                try fields.encode(source.host, forKey: key(.host))
                try fields.encode(source.path, forKey: key(.path))
                try fields.encode(source.remoteID, forKey: key(.remoteID))
                try fields.encode(source.access, forKey: key(.access))
                // Written as null rather than left out, like the records' own.
                try fields.encode(source.trustedAt, forKey: key(.trustedAt))
                try fields.encode(source.addedAt, forKey: key(.addedAt))
            }
        }
    }
}

/// Reading and writing `~/.udeck/sources.json`: a missing file is no source
/// added, a broken one is said and never written over.
public struct SourceStore: Sendable {
    public let url: URL
    /// The official repository, which no entry may be.
    public let official: RepositoryAddress

    public init(paths: UDeckPaths, official: RepositoryAddress = .official) {
        self.url = paths.sourcesFile
        self.official = official
    }

    /// The list, or why the file is broken.
    public func load() -> Result<SourceList, SourceList.Broken> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(SourceList()) }
        do {
            return SourceList.read(try Data(contentsOf: url), official: official)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// `change` made to the list as it is on disk, and written: never over a
    /// broken file, which throws what is wrong with it and writes nothing.
    @discardableResult
    public func modify<T>(_ change: (inout SourceList) throws -> T) throws -> T {
        var list = try load().get()
        let result = try change(&list)
        try JSONFileStore<SourceList>(url: url).save(list)
        return result
    }
}

/// What a source is called on screen: its passport's name, cleaned — or its
/// address, when it has no name of its own to show.
///
/// The passport's `name` is somebody else's text, and it stands next to the
/// address and in the **Trusted source** mark. So characters of the Unicode
/// categories Cc, Cf, Zl and Zp — controls, the zero-width and bidirectional
/// ones among them — are taken out, and what is left is shown inside an
/// isolate (U+2068 … U+2069), so that it cannot reorder what stands beside it.
/// The address is shown instead when no passport has been read, when nothing
/// is left of the name, and when it is — trimmed, whatever its case — the
/// official passport's name or `uDeck plugins`: a passport cannot dress up as
/// the official one.
public enum SourceName {
    /// The name the template's passport and the official one start from.
    public static let reserved = "uDeck plugins"
    static let isolateStart: Unicode.Scalar = "\u{2068}"
    static let isolateEnd: Unicode.Scalar = "\u{2069}"

    /// What `address` is called, its passport named `passportName` — nil
    /// while none has been read — and the official one's `officialName`.
    public static func shown(_ passportName: String?, address: RepositoryAddress, officialName: String?) -> String {
        guard let passportName else { return address.description }
        let name = cleaned(passportName)
        let taken = [reserved] + (officialName.map { [cleaned($0)] } ?? [])
        guard !name.isEmpty, !taken.contains(where: { $0.lowercased() == name.lowercased() }) else {
            return address.description
        }
        return "\(Character(isolateStart))\(name)\(Character(isolateEnd))"
    }

    /// `name` without its controls, format characters and line and paragraph
    /// separators, trimmed.
    static func cleaned(_ name: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: kept.append(scalar)
            }
        }
        return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
