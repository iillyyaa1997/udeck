import Foundation
import UDeckPluginFormat

/// How uDeck schedules a `poll` plugin that keeps failing — uDeck's policy, not
/// part of the format, so it stays here rather than in `UDeckPluginFormat`.
extension PluginManifest {
    /// How the wait grows while a `poll` plugin keeps failing, and how far.
    ///
    /// `RestartPolicy` carries a backoff too, and it is not this one: that
    /// describes what a `resident` plugin does when it exits, and `resident` is
    /// a format that exists so it can be added later without breaking plugins
    /// written today. Nothing implements it. A poll plugin needed its own.
    public static let pollBackoffFactor: Double = 2
    public static let maximumPollBackoff: TimeInterval = 60

    /// How long to wait before polling again, given how many times in a row
    /// this plugin has failed.
    ///
    /// Without this a producer that fails instantly costs exactly what a
    /// working one costs, forever: a process spawned and reaped every interval
    /// for as long as the panel is open. The floor on `interval` bounds how bad
    /// that is; backing off is what makes a broken plugin cheap.
    ///
    /// Never shorter than the interval the plugin asked for, and never longer
    /// than `maximumPollBackoff` — including when the exponent overflows to
    /// infinity, which it does at around a thousand consecutive failures.
    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard let interval else { return 0 }
        guard failures > 0 else { return interval }
        let grown = interval * pow(Self.pollBackoffFactor, Double(failures))
        guard grown.isFinite else { return max(interval, Self.maximumPollBackoff) }
        return max(interval, min(Self.maximumPollBackoff, grown))
    }
}
