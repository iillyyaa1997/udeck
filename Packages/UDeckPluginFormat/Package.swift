// swift-tools-version: 6.0
import PackageDescription

// The plugin format, on its own: what a plugin folder and a plugin repository
// are, and every rule uDeck holds them to — the part of uDeck that has to give
// the same answer on an author's Mac, in a repository's CI on Linux, and inside
// uDeck itself.
//
// A package of its own, beside the app rather than inside its Package.swift,
// because the app's package brings Sparkle (an XCFramework, Apple-only) and a
// test target that needs AppKit's neighbours; neither has any business in a
// Linux build. uDeck links this package by path, so one commit is one version
// of both.
let package = Package(
    name: "UDeckPluginFormat",
    platforms: [
        // swift-testing's floor, and uDeck's.
        .macOS(.v14),
    ],
    products: [
        .library(name: "UDeckPluginFormat", targets: ["UDeckPluginFormat"]),

        // Test helpers shared with uDeck's own tests, which build repositories
        // the same way. Nothing ships them.
        .library(name: "UDeckPluginFormatFixtures", targets: ["UDeckPluginFormatFixtures"]),

        // The command authors and repositories' CI run: `check`, `check-repo`,
        // `new`, `run` and `link`. It travels inside uDeck.app
        // (Contents/Helpers, put there by Scripts/make-app.sh), and Install
        // command in uDeck's Settings links ~/.local/bin to it. Archives of
        // its own for macOS and Linux, a container image and `pin` come with
        // stage 2's wave D.
        .executable(name: "udeck-plugin", targets: ["udeck-plugin"]),

        // What the command does, for the tests that run it — here and from
        // uDeck's own `swift test`. Nothing else links it.
        .library(name: "UDeckPluginCommand", targets: ["UDeckPluginCommand"]),
    ],
    dependencies: [
        // SHA-1 for git's hashes, SHA-256 later for the licence check. On Apple
        // platforms it compiles to nothing and re-exports CryptoKit, so uDeck
        // hashes exactly as it did; elsewhere it brings its own implementation.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
    ],
    targets: [
        .target(
            name: "UDeckPluginFormat",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),

        // What `udeck-plugin` does, apart from being started: its arguments,
        // what it prints and how it exits — a library, so tests can run it.
        .target(name: "UDeckPluginCommand", dependencies: ["UDeckPluginFormat"]),

        .executableTarget(name: "udeck-plugin", dependencies: ["UDeckPluginCommand"]),

        .target(
            name: "UDeckPluginFormatFixtures",
            dependencies: ["UDeckPluginFormat"],
            path: "Tests/UDeckPluginFormatFixtures"
        ),

        .testTarget(
            name: "UDeckPluginFormatTests",
            dependencies: ["UDeckPluginFormat", "UDeckPluginFormatFixtures", "UDeckPluginCommand"],
            // Read from disk by path, like uDeck's own fixtures: a frozen plugin
            // folder whose git hashes are known, and the corpus of repositories
            // the Python check was run on.
            exclude: ["Fixtures", "Corpus"]
        ),

        // How long reading and running take, and whatever keeps a core busy
        // for a second. Apart from the tests above so that uDeck's top-level
        // `swift test`, which builds those but not these, never runs them
        // beside its test of the host's CPU time.
        .testTarget(
            name: "UDeckPluginFormatTimingTests",
            dependencies: ["UDeckPluginFormat", "UDeckPluginFormatFixtures"]
        ),
    ]
)
