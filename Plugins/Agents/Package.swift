// swift-tools-version: 6.0
import PackageDescription

// Agents — a uDeck plugin: AI agents' sessions (Claude Code now, Codex next) on
// a card in the panel. Not part of uDeck: a resident plugin like any other,
// built on the agent protocols in uDeck's repository (UDeckAgents).
let package = Package(
    name: "Agents",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "agents", targets: ["agents"])],
    dependencies: [.package(name: "uDeck", path: "../..")],
    targets: [
        .target(name: "AgentsCore", dependencies: [.product(name: "UDeckAgents", package: "uDeck")]),
        .executableTarget(name: "agents", dependencies: ["AgentsCore"]),
        .testTarget(name: "AgentsCoreTests", dependencies: ["AgentsCore", .product(name: "UDeckAgents", package: "uDeck")]),
    ]
)
