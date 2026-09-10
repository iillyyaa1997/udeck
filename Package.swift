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
    dependencies: [
        // The project's first dependency, and it earns it: Sparkle is what a
        // Mac application outside the App Store uses to update itself, and the
        // parts of that job that look easy — verifying a download, replacing a
        // running bundle, relaunching — are the parts that go wrong quietly.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure model + logic. Foundation and CoreGraphics only — no AppKit, no
        // SwiftUI — so all of it is testable without a window server.
        .target(name: "UDeckCore", path: "Sources/UDeckCore"),

        // Everything that touches AppKit/SwiftUI: the panel window, pointer
        // monitoring, screen observation, card rendering, settings UI.
        .target(name: "UDeckKit", dependencies: ["UDeckCore"], path: "Sources/UDeckKit"),

        .executableTarget(
            name: "uDeck",
            dependencies: [
                "UDeckKit", "UDeckCore",
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

        .testTarget(name: "UDeckCoreTests", dependencies: ["UDeckCore"], path: "Tests/UDeckCoreTests"),
    ]
)
