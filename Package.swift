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
    ],
    dependencies: [],
    targets: [
        // Pure model + logic. Foundation and CoreGraphics only — no AppKit, no
        // SwiftUI — so all of it is testable without a window server.
        .target(name: "UDeckCore", path: "Sources/UDeckCore"),

        // Everything that touches AppKit/SwiftUI: the panel window, pointer
        // monitoring, screen observation, card rendering, settings UI.
        .target(name: "UDeckKit", dependencies: ["UDeckCore"], path: "Sources/UDeckKit"),

        .executableTarget(
            name: "uDeck",
            dependencies: ["UDeckKit", "UDeckCore"],
            path: "Sources/uDeck",
            exclude: ["Support/Info.plist"],
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
                ]),
            ]
        ),

        .testTarget(name: "UDeckCoreTests", dependencies: ["UDeckCore"], path: "Tests/UDeckCoreTests"),
    ]
)
