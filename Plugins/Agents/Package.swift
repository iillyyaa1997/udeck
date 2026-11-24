// swift-tools-version: 6.0
import PackageDescription

// Agents — a uDeck plugin: AI agents' sessions (Claude Code and Codex) on a card
// in the panel. Not part of uDeck: a resident plugin like any other. What
// Claude Code's and Codex's protocols mean lives here (AgentsCore/Protocols);
// from uDeck's repository it takes only the plumbing every plugin's process is
// run with (UDeckAgents: a process, its lines, JSON).
let package = Package(
    name: "Agents",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "agents", targets: ["agents"])],
    dependencies: [.package(name: "uDeck", path: "../..")],
    targets: [
        .target(name: "AgentsCore", dependencies: [.product(name: "UDeckAgents", package: "uDeck")]),
        .executableTarget(name: "agents", dependencies: ["AgentsCore"]),
        .testTarget(name: "AgentsCoreTests", dependencies: ["AgentsCore", .product(name: "UDeckAgents", package: "uDeck")],
                    resources: [.copy("Fixtures")]),
    ]
)
