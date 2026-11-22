// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "uDeck",
    platforms: [
        // macOS 14 is the floor: swift-testing requires it, and every AppKit
        // API uDeck relies on (notch geometry via NSScreen.auxiliaryTop*Area,
        // non-activating NSPanel, NSWorkspace activation notifications) has
        // been available since macOS 12.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "uDeck", targets: ["uDeck"]),
        .library(name: "UDeckCore", targets: ["UDeckCore"]),
        .executable(name: "udeck-agentd", targets: ["udeck-agentd"]),
    ],
    dependencies: [
        // The project's first dependency, and it earns it: Sparkle is what a
        // Mac application outside the App Store uses to update itself, and the
        // parts of that job that look easy — verifying a download, replacing a
        // running bundle, relaunching — are the parts that go wrong quietly.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),

        // The plugin format — manifests, cards, repositories and their rules —
        // in a package of its own, so that it builds on Linux as well, where
        // the check a plugin repository's CI runs needs it. Linked by path: one
        // commit is one version of the app and of the format.
        .package(path: "Packages/UDeckPluginFormat"),
    ],
    targets: [
        // Pure model + logic. Foundation and CoreGraphics only — no AppKit, no
        // SwiftUI — so all of it is testable without a window server.
        .target(
            name: "UDeckCore",
            dependencies: [.product(name: "UDeckPluginFormat", package: "UDeckPluginFormat")],
            path: "Sources/UDeckCore"
        ),

        // Claude Code's and Codex's protocols, with no UI — for the agents plugin
        // to build on, not a part of uDeck: what a line on their stdout means
        // and what to write back. Foundation only, so all of it runs in
        // `swift test` against conversations recorded from the real programs.
        // (The helper below uses only its process and JSON pieces.)
        .target(name: "UDeckAgents", path: "Sources/UDeckAgents"),

        // The helper that owns the agents, `udeck-agentd`, and uDeck's side of
        // the socket to it: agents keep working while uDeck restarts, crashes
        // or updates. The helper pipes bytes and keeps a journal; what the bytes
        // mean stays in UDeckAgents, on uDeck's side.
        .target(name: "UDeckAgentHost", dependencies: ["UDeckAgents"], path: "Sources/UDeckAgentHost"),
        .executableTarget(name: "udeck-agentd", dependencies: ["UDeckAgentHost"], path: "Sources/udeck-agentd"),

        // Everything that touches AppKit/SwiftUI: the panel window, pointer
        // monitoring, screen observation, card rendering, settings UI.
        .target(name: "UDeckKit", dependencies: ["UDeckCore", "UDeckAgents"], path: "Sources/UDeckKit"),

        .executableTarget(
            name: "uDeck",
            dependencies: [
                "UDeckKit", "UDeckCore", "UDeckAgentHost",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/uDeck",
            exclude: [
                "Support/Info.plist", "Support/uDeck.icns",
                "Support/Assets.car", "Support/uDeck.icon",
            ],
            linkerSettings: [
                // Embed Info.plist into __TEXT,__info_plist so the bare SwiftPM
                // binary already behaves as an LSUIElement (no Dock icon, no
                // menu bar). `swift build && .build/debug/uDeck` is therefore a
                // complete dev loop with no bundling step. A packaged .app uses
                // the same file on disk at Contents/Info.plist.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/uDeck/Support/Info.plist",

                    // Where Sparkle.framework lives inside a packaged .app.
                    // SwiftPM leaves the framework next to the binary, which
                    // `@loader_path` already covers for a development build;
                    // this is the same answer for the bundle layout, so one
                    // binary works in both places.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),

        .testTarget(
            name: "UDeckCoreTests",
            dependencies: [
                "UDeckCore",
                .product(name: "UDeckPluginFormatFixtures", package: "UDeckPluginFormat"),
            ],
            path: "Tests/UDeckCoreTests"
        ),

        .testTarget(
            name: "UDeckAgentsTests",
            dependencies: ["UDeckAgents"],
            path: "Tests/UDeckAgentsTests",
            resources: [.copy("Fixtures")]
        ),

        .testTarget(
            name: "UDeckAgentHostTests",
            dependencies: ["UDeckAgentHost", "UDeckAgents"],
            path: "Tests/UDeckAgentHostTests"
        ),

        // The plugin format's own tests, run from here as well: `swift test` in
        // the repository runs every test uDeck has, wherever the code under test
        // lives. A package's tests are not built for the packages that depend
        // on it, so without this they would run only from
        // Packages/UDeckPluginFormat. Named apart from the package's own test
        // target, so that no two targets in one build share a name.
        .testTarget(
            name: "PluginFormatTests",
            dependencies: [
                .product(name: "UDeckPluginFormat", package: "UDeckPluginFormat"),
                .product(name: "UDeckPluginFormatFixtures", package: "UDeckPluginFormat"),
                .product(name: "UDeckPluginCommand", package: "UDeckPluginFormat"),
            ],
            path: "Packages/UDeckPluginFormat/Tests/UDeckPluginFormatTests",
            exclude: ["Fixtures", "Corpus"]
        ),
    ]
)
