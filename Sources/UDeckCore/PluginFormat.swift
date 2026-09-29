// The plugin format — manifests, discovery, cards, repositories and their
// rules — lives in its own package, `Packages/UDeckPluginFormat`, so that the
// same code can check a plugin on Linux, where uDeck itself does not run.
//
// Re-exported, so that everything importing UDeckCore sees those types exactly
// where it always has: they were UDeckCore's before they moved, and nothing
// outside this module needs to know that they did.
@_exported import UDeckPluginFormat
