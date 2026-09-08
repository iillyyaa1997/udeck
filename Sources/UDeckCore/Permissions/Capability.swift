import Foundation

/// One thing a plugin says it needs.
public enum Capability: Hashable, Sendable {
    /// Read files matching a glob.
    case read(String)
    /// Write files matching a glob.
    case write(String)
    /// Run a command, named without a path (`ps`, `kubectl`).
    case exec(String)
    /// Reach a network host.
    case network(String)
    /// Enumerate and switch between running applications.
    case screen
    /// Receive a named secret from the host's keychain entry for it.
    case secret(String)

    public var family: Family {
        switch self {
        case .read: .read
        case .write: .write
        case .exec: .exec
        case .network: .network
        case .screen: .screen
        case .secret: .secret
        }
    }

    public enum Family: String, Codable, Sendable, CaseIterable {
        case read, write, exec, network, screen, secret
    }

    /// The scope: the glob, host or command this capability is about.
    public var scope: String? {
        switch self {
        case .read(let value), .write(let value), .exec(let value),
             .network(let value), .secret(let value): value
        case .screen: nil
        }
    }
}

/// How much of a capability the host can actually hold against a plugin.
///
/// This distinction is the honest part of uDeck's permission model, and it is
/// stated plainly because the alternative — a UI that implies more control than
/// exists — is exactly the kind of reassurance that gets someone burned.
///
/// A plugin is an ordinary executable that the host launches as the user, and
/// uDeck does not sandbox it. Once it is running it can read, write and execute
/// anything the user can. No permission dialog changes that.
///
/// What *is* real:
///
/// * The host decides whether to launch the plugin at all. Declining a required
///   capability means the plugin never runs — enforced, not advisory.
/// * Services the host performs on the plugin's behalf are genuinely gated: a
///   card's action button is run by the host, and the host refuses when `exec`
///   was not granted; secrets are handed over by the host, or not at all.
///
/// So the interface says "this plugin asks for…" rather than "this plugin is
/// forbidden from…", and the difference is not pedantry.
public enum CapabilityEnforcement: Equatable, Sendable {
    /// The host performs the operation and can refuse it.
    case hostMediated

    /// Declared by the plugin and shown to the operator, but a running plugin
    /// process is not prevented from doing it. Withholding the grant stops the
    /// plugin from launching, which is the enforcement that does exist.
    case declaredOnly
}

extension Capability {
    /// How this capability behaves for the plugin's own process.
    public var processEnforcement: CapabilityEnforcement {
        switch self {
        case .secret: .hostMediated
        case .read, .write, .exec, .network, .screen: .declaredOnly
        }
    }

    /// A short line for the permission sheet, in the plugin author's terms.
    public var summary: String {
        switch self {
        case .read(let glob): "read files matching \(glob)"
        case .write(let glob): "write files matching \(glob)"
        case .exec(let command): "run \(command)"
        case .network(let host): "reach \(host) over the network"
        case .screen: "list and switch between running applications"
        case .secret(let name): "receive the secret \"\(name)\" from uDeck"
        }
    }
}

/// What a manifest declares under `permissions`.
public struct PermissionRequest: Codable, Equatable, Sendable {
    public var read: [String]
    public var write: [String]
    public var exec: [String]
    public var network: [String]
    public var screen: Bool
    public var secrets: [String]

    public init(
        read: [String] = [],
        write: [String] = [],
        exec: [String] = [],
        network: [String] = [],
        screen: Bool = false,
        secrets: [String] = []
    ) {
        self.read = read
        self.write = write
        self.exec = exec
        self.network = network
        self.screen = screen
        self.secrets = secrets
    }

    private enum CodingKeys: String, CodingKey { case read, write, exec, network, screen, secrets }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            read: try c.decodeIfPresent([String].self, forKey: .read) ?? [],
            write: try c.decodeIfPresent([String].self, forKey: .write) ?? [],
            exec: try c.decodeIfPresent([String].self, forKey: .exec) ?? [],
            network: try c.decodeIfPresent([String].self, forKey: .network) ?? [],
            screen: try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false,
            secrets: try c.decodeIfPresent([String].self, forKey: .secrets) ?? []
        )
    }

    /// The individual capabilities the operator is asked about, in a stable
    /// order so the permission sheet does not reshuffle between launches.
    public var capabilities: [Capability] {
        var all: [Capability] = []
        all += read.sorted().map(Capability.read)
        all += write.sorted().map(Capability.write)
        all += exec.sorted().map(Capability.exec)
        all += network.sorted().map(Capability.network)
        if screen { all.append(.screen) }
        all += secrets.sorted().map(Capability.secret)
        return all
    }

    public var isEmpty: Bool { capabilities.isEmpty }
}

extension Capability: Codable {
    private enum CodingKeys: String, CodingKey { case family, scope }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let family = try c.decode(Family.self, forKey: .family)
        let scope = try c.decodeIfPresent(String.self, forKey: .scope)

        func requireScope() throws -> String {
            guard let scope else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "capability \"\(family.rawValue)\" needs a scope")
                )
            }
            return scope
        }

        switch family {
        case .read: self = .read(try requireScope())
        case .write: self = .write(try requireScope())
        case .exec: self = .exec(try requireScope())
        case .network: self = .network(try requireScope())
        case .secret: self = .secret(try requireScope())
        case .screen: self = .screen
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(family, forKey: .family)
        try c.encodeIfPresent(scope, forKey: .scope)
    }
}
